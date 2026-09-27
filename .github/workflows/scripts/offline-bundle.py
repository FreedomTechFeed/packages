#!/usr/bin/env python3
"""Build the per-arch OFFLINE dependency bundle for the tollgate-wrt package.

WHY THIS EXISTS
---------------
`net/tollgate-wrt/Makefile` declares `DEPENDS:=+nodogsplash +jq`. On a router
with an uplink those two resolve from OpenWrt's own feeds. A freshly flashed
router with NO uplink has no apk indexes at all, so `apk add <file>.apk`
cannot resolve them and the install fails. This tool produces, per arch, a
single release asset

    tollgate-wrt-<PKG_VERSION>-<arch>-offline.tar.gz

laid out as

    pkgs/               every bundle member .apk, incl. the tollgate-wrt apk
    MANIFEST.sha256     sha256 of every file in the bundle
    install-offline.sh  the ordered no-brick installer (OFFLINE-BUNDLE-2)
    README.md           what the operator needs

HOW THE CLOSURE IS RESOLVED (no guessing, no HTML scraping)
-----------------------------------------------------------
The dependency graph comes from the PUBLISHED apk indexes of the release the
bundle targets -- `<feed>/packages.adb` on downloads.openwrt.org, for the base,
packages, routing, target and (kernel-version-specific) kmods feeds. `.adb` is
apk-tools 3's compiled database format, so it is read with apk-tools' own
`apk adbdump` (a pinned, sha256-verified static apk-tools is provisioned when
the host has none) rather than by scraping directory listings: a listing shows
which FILES exist, not which package PROVIDES a dependency name, and resolving
by filename is how you silently ship an incomplete bundle.

Every dependency edge of every member is then classified EXPLICITLY as one of

    bundle       another member of this bundle ships it
    base-image   the target's base image already provides it (profiles.json
                 default_packages + device_packages, plus the running kernel)
    stub         a stale virtual dependency that no feed provides any more
                 (e.g. libpthread on musl); an empty stub package is generated
    unresolved   nothing satisfies it -> the build FAILS CLOSED and names the
                 dependency and the member that requires it

The closure is only accepted as CLOSED when no edge is unresolved.

SUBCOMMANDS
-----------
  plan      resolve the closure against the published indexes (network + apk)
  fetch     download every member .apk and verify its identity (network + apk)
  assemble  write the bundle dir, MANIFEST.sha256 and the tarball (no network)
  build     plan + fetch + assemble  (what the release workflow runs)

`plan` is hermetic when the cache already holds the index dumps
(`<cache>/idx/<feed>.txt`), which is how the unit tests drive it.

WHAT THE BUILDER GUARANTEES IN THE SHIPPED INSTALLER
----------------------------------------------------
The installer directory is PINNED (OFFLINE_INSTALLER_REF) and shipped VERBATIM,
byte for byte. The builder applies exactly ONE fresh-box repair to the staged
copy (idempotent, required before the bundle may be published) and GUARDS one
further invariant WITHOUT ever editing the file:

  repair_keepalive_seed    the management keepalive seed must be able to create
                           the /etc/config/nodogsplash FILE *and* the anonymous
                           nodogsplash section it writes to (a fresh flash has
                           neither yet, and real `uci add` cannot create a
                           section in a config file that does not exist)

  guard_router_dep_stage   stage (2) of install-router.sh must offer the WHOLE
                           staged closure to apk in one --no-network transaction
                           (apk-tools 3 resolves from the files NAMED plus the
                           installed DB only, so a stage that names just the
                           top-level deps REFUSES on a fresh box), and its gate
                           must report apk's own rc. Upstream PR #178 fixed this
                           AT THE SOURCE, so on the current pin the guard passes
                           and the shipped install-router.sh is byte-identical to
                           the pinned source; the guard never rewrites the file.

The guard is SEMANTIC and COMMENT-INDEPENDENT: it locates the stage by its own
banner and judges what the stage DOES, so it is blind to comments, to
whitespace-only differences and to upstream rewording (an earlier version
rewrote the stage by matching an exact text block plus a marker comment; a
reworded upstream comment made it fail closed on a correct installer, so it was
replaced by this guard).

Both the repair and the guard fail the build closed when the pinned installer is
a REAL router-side installer that is not the shape they can guarantee; a fixture
or synthetic driver is passed through untouched.

EXIT STATUS: 0 = success, 1 = fail closed (the reason is printed with a
`::error::` prefix and named in the closure report), 2 = usage error.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

SCHEMA = 1
DEFAULT_RELEASE = "25.12.5"
DEFAULT_ARCH = "aarch64_cortex-a53"
DEFAULT_TARGET = "mediatek-filogic"
DEFAULT_SEEDS = "nodogsplash,jq"

DOWNLOADS_BASE = "https://downloads.openwrt.org/releases"
FEEDS = ("base", "packages", "routing", "target", "kmods")

# Stale virtual dependencies: no feed provides them any more, but published
# packages still declare them. An EMPTY STUB satisfies apk's resolver only --
# it never satisfies a runtime requirement. Measured 2026-08-17: nodogsplash
# 5.0.2 execs `iptables --version` at startup, so an iptables stub crash-loops
# the daemon; only names listed here may be stubbed.
STALE_VIRTUAL_DEPS = {
    "libpthread": "musl folds pthreads into libc; OpenWrt 25.12 ships no libpthread package",
}

# Never bundled, always base-image-provided: `kernel` is a virtual package whose
# only job is a version match against the running kernel (it has no .apk).
NEVER_BUNDLED = {"kernel"}

# Pinned apk-tools used to read the published .adb indexes when the host has no
# apk-tools 3 of its own. apk-tools 3.0.8 reads OpenWrt 25.12's 3.0.5-written
# ADB (ver 0). `--apk-bin` / $APK_BIN override it.
APK_STATIC_URL = (
    "https://dl-cdn.alpinelinux.org/alpine/edge/main/x86_64/"
    "apk-tools-static-3.0.8-r0.apk"
)
APK_STATIC_SHA256 = "673f1bfb22136fc42ca035321cf731a4ad0452c000928666cb39a138f0c277bf"

MANIFEST_NAME = "MANIFEST.sha256"
INSTALLER_NAME = "install-offline.sh"

# The router-side management keepalive seed, relative to the bundle root. It
# ships INSIDE the bundle (copied from the pinned installer directory) and is
# applied by install-router.sh BEFORE anything can start enforcing. On a
# freshly flashed box /etc/config/nodogsplash does not exist yet, so a seed that
# resolves the anonymous section @nodogsplash[0] cannot land its add_list calls
# (real `uci` exits non-zero; the seed ignores errors and still exits 0) and the
# installer's own keepalive_applied gate then refuses with exit 5 — a bundle
# refused by the gate for a package the bundle itself delivers. The builder
# therefore guarantees the shipped seed can create the config FILE and the
# section it needs.
KEEPALIVE_REL = "templates/99z-mgmt-keepalive"

# TWO independent markers, so the repair never double-applies either step and
# never rewrites a seed that already carries it (the class of bug the
# dependency-stage fix removed from this builder):
#   * the FILE-ensure step (create /etc/config/nodogsplash when it is absent);
#   * the SECTION-ensure step (create the anonymous nodogsplash section).
# The file marker is a regex, not a literal, so an upstream reword (a variable
# holding the path, single vs double quotes, extra spaces) still counts.
KEEPALIVE_FILE_ENSURE_RE = re.compile(
    r'^\s*\[[^\]]*etc/config/nodogsplash"[^\]]*\]\s*\|\|\s*:\s*>\s*'
    r'\S*etc/config/nodogsplash"',
    re.M)
KEEPALIVE_SECTION_MARK = \
    "uci -q get nodogsplash.@nodogsplash[0] >/dev/null 2>&1"

KEEPALIVE_FRESHBOX_HEADER = """\
# --- fresh-box guard (added by the offline bundle builder) -------------------
# A freshly flashed box has NO /etc/config/nodogsplash yet: nodogsplash is one of
# the packages the bundle itself DELIVERS, so it is not installed when this seed
# runs. Real `uci` needs the config FILE to exist before `uci add <cfg> <type>`
# will create a section (it prints "uci: Entry not found" and exits 3 — measured
# on the bench MT3000, 2026-09-28), and it cannot resolve the anonymous section
# @nodogsplash[0] without that file either — so the add_list calls below would
# land nothing (this script ignores errors and still exits 0). install-router.sh
# asserts this pre-auth trust is LIVE *before* it installs anything and otherwise
# refuses with exit 5, so the seed itself has to create the file AND the section
# it needs.
"""

KEEPALIVE_FILE_ENSURE = """\
# Test seam (never set on a router): a harness root standing in for the router's
# filesystem, exactly as install-router.sh uses it. Empty ⇒ real /etc/config/….
[ -f "${TGOFFLINE_ROOT:-}/etc/config/nodogsplash" ] || : > "${TGOFFLINE_ROOT:-}/etc/config/nodogsplash"
"""

KEEPALIVE_SECTION_ENSURE = """\
if ! uci -q get nodogsplash.@nodogsplash[0] >/dev/null 2>&1; then
    uci add nodogsplash nodogsplash
fi
"""

# What a seed that carries NEITHER step gets: both, file first.
KEEPALIVE_FRESHBOX_GUARD = (
    KEEPALIVE_FRESHBOX_HEADER + KEEPALIVE_FILE_ENSURE + KEEPALIVE_SECTION_ENSURE)

# --- the router-side DEPENDENCY stage (stage 2 of install-router.sh) ---------
# The companion script hands apk the dependency files BY PATH. apk-tools 3
# resolves a transaction from the files NAMED on the command line plus the
# installed DB, and from nothing else; with --no-network there is no feed index
# to fall back on, so a dependency of a named package that is NOT itself named is
# `(no such package)` and apk refuses the WHOLE transaction. The pinned script
# names only REQUIRED_DEPS + STUB_OK_DEPS, so it needs every one of THEM to be
# base-image-complete — and nodogsplash is not: it depends on iptables-nft,
# iptables-mod-conntrack-extra, iptables-mod-ipopt and iptables-mod-nat-extra,
# which the bundle DOES carry but the stage never offered to apk. Measured on the
# bench MT3000 (OpenWrt 25.12.5 r33051, aarch64, apk-tools 3.0.5, FRESH flash,
# WAN-less, 2026-09-27 wave 3c — the released pre19 bundle with the fresh-box
# keepalive repair applied):
#
#   + apk add --no-network --allow-untrusted --force-missing-repositories /
#       <stage>/nodogsplash-5.0.2-r2.apk <stage>/jq-1.8.1-r2.apk /
#       <stage>/libmicrohttpd-no-ssl-1.0.2-r1.apk <stage>/libpthread-1.2.5-r5.apk
#   ERROR: unable to select packages:
#     iptables-mod-conntrack-extra (no such package): required by nodogsplash-5.0.2-r2
#     iptables-mod-ipopt (no such package): required by nodogsplash-5.0.2-r2
#     iptables-mod-nat-extra (no such package): required by nodogsplash-5.0.2-r2
#     iptables-nft (no such package): required by nodogsplash-5.0.2-r2
#   REFUSED(7): the offline dependency install failed.
#   gate deps_installed FAIL apk add of the dependency files failed rc=0
#
# The closure was COMPLETE — `gate bundle_closure PASS required deps
# present:nodogsplash jq libmicrohttpd-no-ssl (38 staged package(s))` and all 38
# were staged, iptables-nft included. Only four of them were offered to apk. An
# UPGRADE box already has nodogsplash's deps installed, which is why the offline
# bundle had only ever been exercised on a box where this passes; and it is also
# why stage (2b)'s runtime gate (`iptables --version`, which nodogsplash execs at
# start-up) could never have been reached on a fresh box by an apk that did
# succeed. The stage must offer the whole staged closure, not the top level.
# Upstream PR #178 fixed this at the source, so the builder now GUARDS it
# (guard_router_dep_stage) instead of rewriting the stage: the shipped
# install-router.sh is byte-identical to the pin.
ROUTER_INSTALLER_NAME = "install-router.sh"

# Positive fingerprint of the real OFFLINE-BUNDLE-2 router half. A fixture or
# synthetic driver (the unit tests use both) must be passed through untouched; a
# REAL router-side installer whose dependency stage is not the shape below must
# fail the build closed rather than ship a bundle that refuses on a fresh box.
ROUTER_INSTALLER_FINGERPRINT = ("TGOFFLINE_VERSION=", "apk add --no-network")

# Positive fingerprint of the real OFFLINE-BUNDLE-2 router half. A fixture or
# synthetic driver (the unit tests use both) must be passed through untouched; a
# REAL router-side installer whose dependency stage is not the shape below must
# fail the build closed rather than ship a bundle that refuses on a fresh box.
# Both fragments are shell CODE, not comments, so the fingerprint cannot be
# reworded away without changing behaviour.
ROUTER_INSTALLER_FINGERPRINT = ("TGOFFLINE_VERSION=", "apk add --no-network")

# The stage-(2) dependency-install region is located SEMANTICALLY: from the line
# that announces stage (2) (`=== (2) dependency packages ...`) up to and
# including that stage's `gate_pass deps_installed` line. No comment, marker or
# exact text block is involved, so upstream may reword or drop COMMENTS and
# reindent — both regexes tolerate leading whitespace — without changing the
# verdict. The banner wording and the gate NAME are a pinned interface: a
# reworded banner or a renamed gate is a deliberate re-pin event and fails closed
# (region is None) instead of being guessed at.
DEP_STAGE_BANNER_RE = re.compile(
    r"\(\s*2\s*\)[^\n]*dependenc|dependenc[^\n]*\(\s*2\s*\)", re.IGNORECASE)
DEP_STAGE_END_RE = re.compile(r"^\s*gate_pass\s+deps_installed\b", re.MULTILINE)

# The package under test is the bundle's own tollgate-wrt apk; stage (3) installs
# it on its own, so the dep-stage provenance note counts the OTHER staged files.
ROUTER_PKG_PREFIX = "tollgate-wrt_"


class Fail(Exception):
    """Fail-closed condition: the caller must exit non-zero and say why."""


def log(msg):
    print(msg, flush=True)


def warn(msg):
    print("::warning::%s" % msg, flush=True)


def fail(msg):
    print("::error::%s" % msg, flush=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd, **kwargs):
    """Run a command, return stdout. Raise Fail (fail closed) on non-zero."""
    proc = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if proc.returncode != 0:
        raise Fail("command failed (%d): %s\n%s%s"
                   % (proc.returncode, " ".join(cmd),
                      proc.stdout[-2000:], proc.stderr[-2000:]))
    return proc.stdout


def download(url, dest, expect_sha256=None):
    """Download url to dest atomically. Returns sha256 of the bytes.

    A release job must not die on a transient CDN 404/5xx (measured once while
    building this bundle), so this retries: curl --retry-all-errors when curl is
    available, otherwise urllib with its own retry loop.
    """
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    tmp = dest + ".part"
    curl = shutil.which("curl")
    attempts = 5
    last = ""
    digest = hashlib.sha256()
    for attempt in range(1, attempts + 1):
        digest = hashlib.sha256()
        try:
            if curl:
                proc = subprocess.run(
                    [curl, "-fsSL", "--retry", "5", "--retry-all-errors",
                     "--retry-delay", "3", "--connect-timeout", "30", "-o", tmp, url],
                    capture_output=True, text=True)
                if proc.returncode != 0:
                    stderr = (proc.stderr or "").strip()
                    # 404 is a hard answer for a release object (a feed that does
                    # not exist for this release/target, or a wrong target path).
                    # Retrying it only delays the fail-closed path.
                    if proc.returncode == 22 and " 404" in stderr:
                        raise Fail("not found (404): %s" % url)
                    raise Fail("curl exit %d: %s" % (proc.returncode, stderr))
                with open(tmp, "rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        digest.update(chunk)
            else:
                with urllib.request.urlopen(url, timeout=120) as resp, open(tmp, "wb") as out:
                    while True:
                        chunk = resp.read(1 << 16)
                        if not chunk:
                            break
                        digest.update(chunk)
                        out.write(chunk)
            break
        except (Fail, urllib.error.URLError, urllib.error.HTTPError, OSError) as exc:
            if isinstance(exc, urllib.error.HTTPError) and exc.code == 404:
                raise Fail("not found (404): %s" % url)
            last = str(exc)
            warn("download attempt %d/%d failed for %s: %s" % (attempt, attempts, url, exc))
            if attempt == attempts:
                raise Fail("could not download %s: %s" % (url, last))
            # Back off between attempts: a CDN edge that is serving 404 for an
            # object it should have keeps doing so for a few seconds.
            time.sleep(min(5 * attempt, 30))
    got = digest.hexdigest()
    if expect_sha256 and got != expect_sha256:
        os.unlink(tmp)
        raise Fail("checksum mismatch for %s: expected %s, got %s"
                   % (url, expect_sha256, got))
    os.replace(tmp, dest)
    return got


# --------------------------------------------------------------------------
# apk-tools provider: adbdump the published indexes, verify .apk identity, and
# generate stub packages. apk-tools 3 is the only correct reader of .adb.
# --------------------------------------------------------------------------
class Apk(object):
    def __init__(self, argv):
        self.argv = list(argv)

    def _run(self, args):
        return run(self.argv + list(args))

    def version(self):
        out = self._run(["--version"])
        return out.strip()

    def adbdump(self, path):
        return self._run(["adbdump", path])

    def mkpkg(self, out_path, info):
        args = ["mkpkg"]
        for key, value in info:
            args += ["--info", "%s:%s" % (key, value)]
        args += ["-o", out_path]
        self._run(args)
        return out_path


def provide_apk(explicit, cache_dir):
    """Return an Apk provider: --apk-bin/$APK_BIN, a native apk-tools>=3, or a
    pinned sha256-verified apk-tools-static (apk mkpkg exists only there)."""
    if explicit:
        return Apk([explicit])
    env_bin = os.environ.get("APK_BIN")
    if env_bin:
        return Apk([env_bin])
    native = shutil.which("apk")
    if native:
        try:
            apk = Apk([native])
            if apk.version().startswith("apk-tools 3"):
                return apk
            warn("ignoring %s: %s (need apk-tools 3 to read .adb)" % (native, apk.version()))
        except Fail:
            warn("ignoring %s: not usable" % native)
    static = os.path.join(cache_dir, "apk.static")
    if not os.path.exists(static):
        log("providing apk-tools from %s" % APK_STATIC_URL)
        pkg = os.path.join(cache_dir, "apk-tools-static.apk")
        download(APK_STATIC_URL, pkg, expect_sha256=APK_STATIC_SHA256)
        with tarfile.open(pkg) as tar:
            member = None
            for name in tar.getnames():
                if name.endswith("apk.static"):
                    member = name
                    break
            if member is None:
                raise Fail("no apk.static inside %s" % APK_STATIC_URL)
            tar.extract(member, cache_dir)
        extracted = os.path.join(cache_dir, member)
        shutil.move(extracted, static)
        os.chmod(static, 0o755)
    return Apk([static])


# --------------------------------------------------------------------------
# adbdump parsing
# --------------------------------------------------------------------------
ENTRY_RE = re.compile(r"^  - ([A-Za-z0-9._-]+):(.*)$")
FIELD_RE = re.compile(r"^    ([A-Za-z0-9._-]+):(.*)$")
LIST_ITEM_RE = re.compile(r"^      - (.*)$")


def parse_index_dump(text):
    """Parse the textual `apk adbdump` representation of an index.

    Entries look like:

        packages: # 2 items
          - name: alpha
            version: 1.0-r1
            description: |
              a multi line block whose body must NOT be read as fields
            depends: # 2 items
              - beta
              - libpthread

    Returns a list of dicts; `depends` and `provides` come back as lists.
    """
    entries = []
    cur = None
    field = None
    in_block = False
    for raw in text.split("\n"):
        line = raw.rstrip("\r")
        match = ENTRY_RE.match(line)
        if match:
            if cur is not None:
                entries.append(cur)
            cur = {match.group(1): match.group(2).strip()}
            field = None
            in_block = False
            continue
        if cur is None:
            continue
        if in_block:
            # Continuation lines of a `|` block are indented deeper than the
            # field itself and never introduce a field or a list item.
            if line.strip() == "" or line.startswith("      "):
                continue
            in_block = False
        match = FIELD_RE.match(line)
        if match:
            key, value = match.group(1), match.group(2).strip()
            field = key
            if value == "|":
                in_block = True
                cur[key] = ""
            elif re.match(r"^# \d+ items$", value):
                cur[key] = []
            else:
                cur[key] = value
            continue
        match = LIST_ITEM_RE.match(line)
        if match and field:
            items = cur.get(field)
            if not isinstance(items, list):
                raise Fail("adbdump parse: list item under scalar field %r" % field)
            items.append(match.group(1).strip())
            continue
        in_block = False
    if cur is not None:
        entries.append(cur)
    # `depends: foo` (a single, unnumbered dependency) is legal too.
    for entry in entries:
        for key in ("depends", "provides"):
            value = entry.get(key)
            if isinstance(value, str):
                entry[key] = [value] if value else []
            elif value is None:
                entry[key] = []
    return entries


def parse_apk_info(text):
    """Parse `apk adbdump <file>.apk` -> the package's own identity."""
    info = {}
    in_info = False
    in_block = False
    for raw in text.split("\n"):
        line = raw.rstrip("\r")
        if line.strip() == "info:":
            in_info = True
            continue
        if not in_info:
            continue
        if in_block:
            if line.strip() == "" or line.startswith("    "):
                continue
            in_block = False
        match = re.match(r"^  ([A-Za-z0-9._-]+):(.*)$", line)
        if match:
            key, value = match.group(1), match.group(2).strip()
            if value == "|":
                in_block = True
            else:
                info[key] = value
    return info


# --------------------------------------------------------------------------
# Dependency expressions
# --------------------------------------------------------------------------
CONSTRAINT_RE = re.compile(r"^([^<>=~!\s]+)\s*([<>=~]+)\s*(\S+)$")


def split_dep(dep):
    """-> (name, operator, version) for 'name>=1.2', ('kernel', '=', '6.12.94')…"""
    dep = dep.strip()
    match = CONSTRAINT_RE.match(dep)
    if match:
        return match.group(1), match.group(2), match.group(3)
    return dep, None, None


def is_foreign_dep(name):
    """so:/cmd:/pc:/absolute-path dependencies are not feed package names."""
    return name.startswith(("so:", "cmd:", "pc:", "/"))


# --------------------------------------------------------------------------
# Closure resolution
# --------------------------------------------------------------------------
class Closure(object):
    def __init__(self, entries, feeds_of):
        self.by_name = {}
        self.by_provide = {}
        self.feed_of = {}          # name -> feed
        for name, entry in entries:
            if name not in self.by_name:
                self.by_name[name] = entry
                self.feed_of[name] = feeds_of[name]
            for provided in entry.get("provides", []):
                self.by_provide.setdefault(provided, name)

    def resolve(self, name):
        """-> (kind, resolved_name) with kind in package|provide|absent."""
        if name in self.by_name:
            return "package", name
        if name in self.by_provide:
            return "provide", self.by_provide[name]
        return "absent", name


def resolve_closure(closure, seeds, base_packages, stub_allow, never_bundled,
                    extra_base=()):
    """Walk the FULL transitive closure of `seeds`.

    Returns a report dict. Every dependency edge carries an explicit
    classification, and any edge that nothing satisfies is recorded in
    `unresolved` (the caller fails closed).
    """
    base = set(base_packages) | set(extra_base) | set(never_bundled)
    members = {}          # resolved name -> entry
    edges = {}            # resolved name -> [dep strings]
    base_provided = {}    # name -> who needed it
    stubbed = {}          # name -> who needed it
    unresolved = []       # {dependency, required_by, reason}

    # stack items: (dependency expression, required_by)
    stack = [(seed, "(seed)") for seed in seeds]
    while stack:
        dep, required_by = stack.pop()
        name, op, version = split_dep(dep)
        if is_foreign_dep(name):
            unresolved.append({
                "dependency": dep, "required_by": required_by,
                "reason": "not a feed package name (shared-library/command/path "
                          "dependency); the bundle cannot provide it",
            })
            continue
        if name in never_bundled:
            base_provided.setdefault(name, required_by)
            continue
        if name in base:
            base_provided.setdefault(name, required_by)
            continue
        if name in members:
            continue
        kind, resolved = closure.resolve(name)
        if kind == "absent":
            if name in stub_allow:
                if op is not None:
                    unresolved.append({
                        "dependency": dep, "required_by": required_by,
                        "reason": "stale virtual dependency with a version "
                                  "constraint (%s%s%s) cannot be satisfied by a "
                                  "stub" % (name, op, version),
                    })
                    continue
                stubbed.setdefault(name, required_by)
                continue
            unresolved.append({
                "dependency": dep, "required_by": required_by,
                "reason": "no package in any published feed provides %r" % name,
            })
            continue
        if resolved in base or resolved in never_bundled:
            base_provided.setdefault(resolved, required_by)
            continue
        if resolved in members:
            continue
        entry = closure.by_name[resolved]
        members[resolved] = entry
        deps = list(entry.get("depends", []))
        edges[resolved] = deps
        for child in deps:
            stack.append((child, resolved))

    member_report = []
    for name in sorted(members):
        entry = members[name]
        dep_edges = []
        for dep in edges.get(name, []):
            child, op, version = split_dep(dep)
            if is_foreign_dep(child):
                status = "unresolved"
            elif child in members:
                status = "bundle"
            elif child in base_provided:
                status = "base-image"
            elif child in stubbed:
                status = "stub"
            else:
                # A provider reached through `provides` is a bundle member
                # under its providing name.
                kind, resolved = closure.resolve(child)
                if kind == "provide" and resolved in members:
                    status = "bundle"
                elif kind != "absent" and closure.resolve(child)[1] in base_provided:
                    status = "base-image"
                else:
                    status = "unresolved"
            dep_edges.append({"dependency": dep, "status": status})
        member_report.append({
            "name": name,
            "version": entry.get("version", ""),
            "arch": entry.get("arch", ""),
            "feed": closure.feed_of.get(name, ""),
            "file": "%s-%s.apk" % (name, entry.get("version", "")),
            "depends": dep_edges,
        })

    return {
        "schema": SCHEMA,
        "seeds": list(seeds),
        "members": member_report,
        "member_count": len(member_report),
        "base_provided": [{"name": n, "required_by": base_provided[n]}
                          for n in sorted(base_provided)],
        "stubbed": [{"name": n, "required_by": stubbed[n],
                     "reason": stub_allow.get(n, "")} for n in sorted(stubbed)],
        "unresolved": unresolved,
        "closure_closed": not unresolved,
    }


# --------------------------------------------------------------------------
# plan
# --------------------------------------------------------------------------
def indexes_dir(cache_dir):
    return os.path.join(cache_dir, "idx")


def target_path_candidates(target):
    """Downloads URL path candidates for a target.

    OpenWrt names IMAGES after the hyphenated target (`mediatek-filogic`), but
    serves them under `targets/<target>/<subtarget>/` (a SLASH). Measured: a
    request for targets/mediatek-filogic/profiles.json 404s while
    targets/mediatek/filogic/profiles.json is 200, so the hyphenated form a
    workflow matrix carries must be translated, not used verbatim.
    A target whose download dir is a single segment (ramips/mt7621 is served as
    targets/ramips/mt7621) needs --target-path.
    """
    candidates = []
    if "/" in target:
        candidates.append(target)
    else:
        if "-" in target:
            candidates.append(target.replace("-", "/", 1))
        candidates.append(target)
    seen = []
    for candidate in candidates:
        if candidate not in seen:
            seen.append(candidate)
    return seen


def feed_urls(release, target_path, arch, kmods_dir, base=DOWNLOADS_BASE):
    root = "%s/%s" % (base.rstrip("/"), release)
    return {
        "base": "%s/packages/%s/base" % (root, arch),
        "packages": "%s/packages/%s/packages" % (root, arch),
        "routing": "%s/packages/%s/routing" % (root, arch),
        "target": "%s/targets/%s/packages" % (root, target_path),
        "kmods": "%s/targets/%s/kmods/%s" % (root, target_path, kmods_dir),
    }


def profiles_cache_path(cache_dir, release, target_path):
    slug = "%s-%s" % (release, target_path.replace("/", "-"))
    return os.path.join(cache_dir, "profiles-%s.json" % slug)


def load_profiles(cache_dir, release, target_path, base=DOWNLOADS_BASE, refresh=False):
    path = profiles_cache_path(cache_dir, release, target_path)
    if refresh or not os.path.exists(path):
        url = "%s/%s/targets/%s/profiles.json" % (base.rstrip("/"), release, target_path)
        download(url, path)
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def kmods_dir_from_profiles(profiles):
    kernel = profiles.get("linux_kernel") or {}
    missing = [k for k in ("version", "release", "vermagic") if not kernel.get(k)]
    if missing:
        raise Fail("profiles.json linux_kernel lacks %s; pass --kmods-dir"
                   % ",".join(missing))
    return "%s-%s-%s" % (kernel["version"], kernel["release"], kernel["vermagic"])


def read_base_packages_file(path):
    names = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                names.append(line)
    return names


def cmd_plan(args):
    cache_dir = os.path.abspath(args.cache_dir)
    os.makedirs(indexes_dir(cache_dir), exist_ok=True)
    apk = None

    profiles = None
    kmods_dir = args.kmods_dir
    target_path = args.target_path
    if not target_path:
        candidates = target_path_candidates(args.target)
        failures = []
        for candidate in candidates:
            try:
                if not kmods_dir or not args.base_packages:
                    profiles = load_profiles(cache_dir, args.release, candidate,
                                             base=args.downloads_base,
                                             refresh=args.refresh)
                target_path = candidate
                break
            except Fail as exc:
                failures.append("%s (%s)" % (candidate, exc))
        if not target_path:
            raise Fail("no download path for target %r: tried %s — pass "
                       "--target-path, e.g. --target-path ramips/mt7621"
                       % (args.target, "; ".join(failures)))
        if target_path != args.target:
            log("target %s is served at targets/%s/" % (args.target, target_path))
    elif not kmods_dir or not args.base_packages:
        profiles = load_profiles(cache_dir, args.release, target_path,
                                 base=args.downloads_base, refresh=args.refresh)

    if not kmods_dir:
        kmods_dir = kmods_dir_from_profiles(profiles)

    urls = feed_urls(args.release, target_path, args.arch, kmods_dir,
                     base=args.downloads_base)
    feeds = [f for f in (args.feeds.split(",") if args.feeds else FEEDS) if f]

    base_packages = []
    if profiles is not None and not args.base_packages:
        base_packages = list(profiles.get("default_packages", []))
        if args.profile:
            profile = (profiles.get("profiles") or {}).get(args.profile)
            if profile is None:
                raise Fail("profile %r is not in %s profiles.json" % (args.profile, target_path))
            base_packages += list(profile.get("device_packages", []))
        log("base image packages from profiles.json: %d (profile=%s)"
            % (len(base_packages), args.profile or "(default_packages only)"))
    if args.base_packages:
        extra = read_base_packages_file(args.base_packages)
        base_packages += extra
        log("base image packages from %s: %d" % (args.base_packages, len(extra)))

    entries = []
    feeds_of = {}
    feed_state = {}
    for feed in feeds:
        dump = os.path.join(indexes_dir(cache_dir), "%s.txt" % feed)
        adb = os.path.join(indexes_dir(cache_dir), "%s.adb" % feed)
        if os.path.exists(dump) and not args.refresh:
            log("index %-8s cached (%s)" % (feed, dump))
        else:
            if apk is None:
                apk = provide_apk(args.apk_bin, cache_dir)
            if args.refresh or not os.path.exists(adb):
                try:
                    download("%s/packages.adb" % urls[feed], adb)
                except Fail as exc:
                    warn("feed %s: %s" % (feed, exc))
                    feed_state[feed] = "missing"
                    continue
            with open(dump, "w", encoding="utf-8") as fh:
                fh.write(apk.adbdump(adb))
            log("index %-8s fetched (%s)" % (feed, urls[feed]))
        with open(dump, encoding="utf-8") as fh:
            parsed = parse_index_dump(fh.read())
        feed_state[feed] = len(parsed)
        for entry in parsed:
            name = entry.get("name")
            if not name:
                continue
            entries.append((name, entry))
            feeds_of.setdefault(name, feed)
        log("index %-8s %d packages" % (feed, len(parsed)))

    closure = Closure(entries, feeds_of)

    seeds = [s for s in args.seeds.split(",") if s]
    if args.tollgate_apk:
        if apk is None:
            apk = provide_apk(args.apk_bin, cache_dir)
        info = parse_apk_info(apk.adbdump(args.tollgate_apk))
        if info.get("arch") not in (args.arch, "noarch"):
            raise Fail("tollgate package arch %r does not match --arch %s"
                       % (info.get("arch"), args.arch))
        package_seeds = [split_dep(d)[0] for d in
                         parse_apk_depends(apk.adbdump(args.tollgate_apk))]
        log("tollgate package %s %s declares: %s"
            % (info.get("name"), info.get("version"), ", ".join(package_seeds) or "(none)"))
        seeds = sorted(set(seeds) | {s for s in package_seeds if s not in NEVER_BUNDLED})

    stub_allow = dict(STALE_VIRTUAL_DEPS)
    for name in (args.allow_stub or "").split(","):
        if name:
            stub_allow[name] = "explicitly allowed by --allow-stub"

    report = resolve_closure(closure, seeds, base_packages, stub_allow, NEVER_BUNDLED)
    report.update({
        "release": args.release,
        "arch": args.arch,
        "target": args.target,
        "target_path": target_path,
        "profile": args.profile or "",
        "kmods_dir": kmods_dir,
        "downloads_base": args.downloads_base,
        "feeds": {f: {"url": urls[f], "packages": feed_state.get(f, 0)} for f in feeds},
        "base_package_count": len(base_packages),
    })

    out = args.out or os.path.join(cache_dir, "plan.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print_plan_report(report)
    log("plan written to %s" % out)
    if report["unresolved"]:
        for item in report["unresolved"]:
            fail("%s is required by %s: %s"
                 % (item["dependency"], item["required_by"], item["reason"]))
        return 1
    return 0


def parse_apk_depends(dump):
    """The `depends` list of an .apk's own metadata dump."""
    deps = []
    in_depends = False
    for raw in dump.split("\n"):
        line = raw.rstrip("\r")
        if re.match(r"^  depends:\s*# \d+ items\s*$", line) or line.strip() == "depends:":
            in_depends = True
            continue
        if in_depends:
            match = re.match(r"^    - (.*)$", line)
            if match:
                deps.append(match.group(1).strip())
                continue
            if re.match(r"^  [A-Za-z0-9._-]+:", line) or line.strip() == "":
                if line.strip() == "":
                    continue
                in_depends = False
    return deps


def print_plan_report(report):
    log("")
    log("--- dependency closure for %s / %s / %s (OpenWrt %s)"
        % (report["arch"], report["target"], report["profile"] or "default",
           report["release"]))
    log("members to bundle: %d" % report["member_count"])
    for member in report["members"]:
        log("  + %-34s %-16s %s" % (member["name"], member["version"], member["feed"]))
    log("provided by the base image (%d): %s"
        % (len(report["base_provided"]),
           ", ".join(e["name"] for e in report["base_provided"]) or "(none)"))
    log("stubbed stale virtual dependencies (%d): %s"
        % (len(report["stubbed"]),
           ", ".join(e["name"] for e in report["stubbed"]) or "(none)"))
    log("unresolved: %d" % len(report["unresolved"]))
    log("closure closed: %s" % ("YES" if report["closure_closed"] else "NO"))


# --------------------------------------------------------------------------
# fetch
# --------------------------------------------------------------------------
def cmd_fetch(args):
    cache_dir = os.path.abspath(args.cache_dir)
    plan = load_plan(args.plan or os.path.join(cache_dir, "plan.json"))
    apks_dir = os.path.join(cache_dir, "apks")
    os.makedirs(apks_dir, exist_ok=True)
    apk = provide_apk(args.apk_bin, cache_dir)

    fetched = []
    for member in plan["members"]:
        feed = member["feed"]
        feed_url = (plan.get("feeds", {}).get(feed, {}) or {}).get("url", "")
        if not feed_url:
            raise Fail("no feed URL for %s (%s): the plan was produced from a cache "
                       "without feed URLs, so the .apk cannot be downloaded"
                       % (feed, member["name"]))
        url = "%s/%s" % (feed_url, member["file"])
        dest = os.path.join(apks_dir, member["file"])
        if os.path.exists(dest) and not args.refresh:
            try:
                verify_apk_identity(apk, dest, member["name"], member["version"], plan["arch"])
                fetched.append(record_member(member, dest, url))
                log("have %s" % member["file"])
                continue
            except Fail as exc:
                warn("re-downloading %s: %s" % (member["file"], exc))
        download(url, dest)
        verify_apk_identity(apk, dest, member["name"], member["version"], plan["arch"])
        fetched.append(record_member(member, dest, url))
        log("fetched %s (%d bytes)" % (member["file"], os.path.getsize(dest)))

    stubs = []
    for entry in plan["stubbed"]:
        name = entry["name"]
        stub_name = "%s-stub-1.0.apk" % name
        dest = os.path.join(apks_dir, stub_name)
        if not os.path.exists(dest) or args.refresh:
            apk.mkpkg(dest, [
                ("name", name),
                ("version", "1.0"),
                ("arch", plan["arch"]),
                ("description", "virtual stub: %s" % entry.get("reason", "")),
                ("license", "MIT"),
            ])
        info = parse_apk_info(apk.adbdump(dest))
        if info.get("name") != name:
            raise Fail("generated stub %s reports name %r, expected %r"
                       % (dest, info.get("name"), name))
        stubs.append({"name": name, "file": stub_name, "kind": "stub",
                      "sha256": sha256_file(dest), "size": os.path.getsize(dest),
                      "source": "generated empty stub (apk mkpkg)",
                      "path": os.path.abspath(dest)})
        log("stub %s (%d bytes)" % (stub_name, os.path.getsize(dest)))

    if args.tollgate_apk:
        dest = os.path.abspath(args.tollgate_apk)
        info = parse_apk_info(apk.adbdump(dest))
        if info.get("arch") not in (plan["arch"], "noarch"):
            raise Fail("tollgate package arch %r does not match %s"
                       % (info.get("arch"), plan["arch"]))
        fetched.append({"name": info.get("name", "tollgate-wrt"),
                        "version": info.get("version", ""),
                        "kind": "tollgate-package",
                        "file": os.path.basename(dest),
                        "sha256": sha256_file(dest), "size": os.path.getsize(dest),
                        "source": os.path.abspath(dest),
                        "path": os.path.abspath(dest)})
        log("tollgate package %s" % os.path.basename(dest))

    payload = {
        "schema": SCHEMA,
        "release": plan["release"],
        "arch": plan["arch"],
        "target": plan["target"],
        "profile": plan.get("profile", ""),
        "members": fetched + stubs,
        "member_count": len(fetched) + len(stubs),
        "base_provided": plan["base_provided"],
        "stubbed": plan["stubbed"],
        "closure_closed": plan["closure_closed"],
        "apks_dir": apks_dir,
    }
    out = args.out or os.path.join(cache_dir, "payload.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    log("payload written to %s (%d files)" % (out, payload["member_count"]))
    if not args.tollgate_apk:
        warn("no --tollgate-apk given: the bundle has no tollgate-wrt package")
    return 0


def verify_apk_identity(apk, path, name, version, arch):
    """A downloaded .apk must BE the package the index said it is."""
    info = parse_apk_info(apk.adbdump(path))
    if info.get("name") != name:
        raise Fail("%s reports name %r, expected %r" % (path, info.get("name"), name))
    if version and info.get("version") != version:
        raise Fail("%s reports version %r, expected %r"
                   % (path, info.get("version"), version))
    if info.get("arch") not in (arch, "noarch"):
        raise Fail("%s reports arch %r, expected %s" % (path, info.get("arch"), arch))


def record_member(member, dest, url):
    return {"name": member["name"], "version": member["version"],
            "kind": "package", "feed": member["feed"], "file": member["file"],
            "sha256": sha256_file(dest), "size": os.path.getsize(dest),
            "source": url, "path": os.path.abspath(dest)}


def load_plan(path):
    if not os.path.exists(path):
        raise Fail("no plan at %s: run `plan` first" % path)
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------
# assemble
# --------------------------------------------------------------------------
def write_manifest(directory):
    """Manifest covering EVERY file under `directory` (never the manifest)."""
    files = []
    for root, dirs, names in os.walk(directory):
        dirs.sort()
        for name in sorted(names):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, directory)
            if rel == MANIFEST_NAME:
                continue
            files.append((rel, path))
    files.sort()
    lines = []
    for rel, path in files:
        lines.append("%s  %s" % (sha256_file(path), rel))
    manifest = os.path.join(directory, MANIFEST_NAME)
    with open(manifest, "w", encoding="utf-8") as fh:
        fh.write("".join(line + "\n" for line in lines))
    return manifest, len(lines)


def readme_text(payload, version, installer_note, layout):
    names = sorted(m["name"] for m in payload["members"])
    base = ", ".join(e["name"] for e in payload["base_provided"]) or "(none)"
    stubs = ", ".join(e["name"] for e in payload["stubbed"]) or "(none)"
    return """# tollgate-wrt %s — offline dependency bundle (%s)

Every package this bundle installs, fetched from the PUBLISHED apk indexes of
OpenWrt %s for `%s` / `%s`. The router itself needs NO uplink.

## Contents

%s

Members (%d):

%s

Provided by the base image, so NOT bundled (%s): %s
Stubbed stale virtual dependencies (%s): %s

## Install (from a machine that HAS internet)

    curl -fsSL <bundle-url> | tar -xz
    ./install-offline.sh <router> <password>

The workstation downloads the bundle; the router never needs the uplink.

## Verify before you install

    sha256sum --check --strict MANIFEST.sha256

The bundle is a release asset, so its own sha256 is covered by the release's
signed SHA256SUMS (`SHA256SUMS.sig`) — that signature is the provenance chain
for these bytes. `install-offline.sh` re-checks the manifest before it writes
anything to the router.

## Provenance

built by `.github/workflows/scripts/offline-bundle.py` inside the release job,
BEFORE `SHA256SUMS` is signed, from the apk indexes listed below. The closure
was proven CLOSED: every dependency of every member is either another member of
this bundle or already in the base image.

%s

## Limitations

* The `.ipk` / OpenWrt <= 24.x (`opkg`) lane is NOT covered: this bundle is the
  apk-tools 3 lane only (OpenWrt 25.x).
* The dependency closure is resolved for the release and target above. Flashing
  a different OpenWrt release or target needs a bundle built for that pair.
""" % (version, payload["arch"], payload["release"], payload["arch"],
       payload["target"],
       "\n".join("    %s" % line for line in layout),
       payload["member_count"], "\n".join("    %s" % n for n in names) or "    (none)",
       len(payload["base_provided"]), base,
       len(payload["stubbed"]), stubs, installer_note)


def repair_keepalive_seed(bundle_dir):
    """Make the bundle's management keepalive seed FRESH-BOX safe.

    Returns a one-line note for the installer provenance block, or "" when the
    bundle carries no seed (the router-side installer refuses such a bundle, and
    the release job asserts the seed is present before it gets here).

    On a freshly flashed box `/etc/config/nodogsplash` is ABSENT until the
    nodogsplash package is installed, which happens AFTER this seed is applied.
    A seed that goes straight to `uci add_list nodogsplash.@nodogsplash[0].<opt>`
    cannot resolve the anonymous section there: real `uci` exits non-zero, the
    seed ignores errors (it ends `exit 0`), and `assert_keepalive_live()` in
    install-router.sh then finds no trustedmac / no `allow tcp port 22` and
    REFUSES with exit 5 before installing anything. That is the chicken-and-egg:
    the installer's pre-install safety gate depends on the package the bundle
    delivers. Measured on the bench MT3000 (fresh flash, OpenWrt 25.12.5,
    2026-09-27 wave 3); an UPGRADE passes, which is why only the fresh flash saw
    it.

    Creating the SECTION is not enough on its own: real `uci` also needs the
    config FILE to exist before `uci add <cfg> <type>` will create a section
    there (bench MT3000, fresh flash, 2026-09-28 — `uci add nodogsplash
    nodogsplash` exited 3 with "uci: Entry not found"; with the file created
    first the very same call exited 0). So the repair guarantees BOTH steps, in
    this order, immediately before the seed's first nodogsplash `uci` call:
    create the (empty) config file when it is absent — never clobbering an
    existing one — and then create the anonymous section when it is absent.

    It is idempotent PER STEP: whichever steps the seed already carries are left
    byte-for-byte, and a seed that carries both is returned untouched (no
    rewrite, no re-application), so a moving pin can adopt upstream's own fix
    without this builder fighting it.
    """
    path = os.path.join(bundle_dir, KEEPALIVE_REL)
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    has_file = bool(KEEPALIVE_FILE_ENSURE_RE.search(text))
    has_section = KEEPALIVE_SECTION_MARK in text
    if has_file and has_section:
        log("keepalive seed already creates the nodogsplash config file and the "
            "anonymous section (fresh-box safe): %s left unchanged" % KEEPALIVE_REL)
        return ("seed: fresh-box safe (carries the file-ensure + section guard), "
                "sha256 %s" % sha256_file(path))
    lines = text.splitlines(keepends=True)
    idx = None
    for i, line in enumerate(lines):
        if "uci" in line and "nodogsplash" in line:
            idx = i
            break
    if idx is None:
        raise Fail(
            "the management keepalive seed (%s) never touches nodogsplash, so "
            "applying it cannot establish the pre-auth trust (trustedmac + "
            "'allow tcp port 22') the router-side installer asserts before it "
            "installs anything — it is not a keepalive seed. Refusing to ship "
            "it." % KEEPALIVE_REL)
    insert = [KEEPALIVE_FRESHBOX_HEADER]
    if not has_file:
        insert.append(KEEPALIVE_FILE_ENSURE)
    if not has_section:
        insert.append(KEEPALIVE_SECTION_ENSURE)
    lines[idx:idx] = insert
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("".join(lines))
    os.chmod(path, 0o755)
    missing = "+".join(n for n, ok in (("file-ensure", has_file),
                                       ("section", has_section)) if not ok)
    log("keepalive seed: inserted the fresh-box guard (%s) before line %d of %s — "
        "a box with no /etc/config/nodogsplash can now establish the pre-auth "
        "trust the router-side installer asserts"
        % (missing, idx + 1, KEEPALIVE_REL))
    return ("seed: fresh-box guard inserted (%s), sha256 %s"
            % (missing, sha256_file(path)))


# --- the dep-stage guard's shell reader --------------------------------------
# The guard must judge what the stage EXECUTES, and nothing else, so it reads the
# shell rather than matching a bag of tokens: comments and here-doc bodies are
# not code and are dropped, a mention of `apk add` inside a string is not a
# command, and only a REAL command's own argument list is judged.


def _scan_shell_line(line):
    """Return (code, heredocs) for one raw shell line.

    `code` is `line` with any COMMENT removed — a word-initial `#` outside quotes
    (shell's own rule, which leaves `${x#y}`, `$#` and `a#b` intact) and
    everything after it. `heredocs` lists (delimiter, dash) for every here-doc
    redirection announced on the line, in order.
    """
    out = []
    heredocs = []
    i, n = 0, len(line)
    sq = dq = False
    while i < n:
        ch = line[i]
        if ch == "\\" and not sq:
            out.append(line[i:i + 2])
            i += 2
            continue
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif not sq and not dq:
            if ch == "#" and (i == 0 or line[i - 1] in " \t;&|("):
                break                        # a comment: the rest is not code
            if line.startswith("<<", i):
                m = re.match(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1",
                             line[i:])
                if m:
                    heredocs.append((m.group(2), m.group(0).startswith("<<-")))
                    out.append(m.group(0))
                    i += m.end()
                    continue
        out.append(ch)
        i += 1
    return "".join(out), heredocs


def _shell_code_lines(text):
    """Return `text`'s executable lines: comments and here-doc BODIES removed.

    A here-doc body (and its terminator line) is data, never executed, so it
    contributes no words to the guard's judgement — a compliant `apk add` quoted
    inside a `cat <<'DOC'` example can therefore never stand in for the real one.
    """
    kept = []
    queue = []                    # here-docs announced whose bodies are pending
    for raw in text.splitlines():
        if queue:
            delim, dash = queue[0]
            if (raw.lstrip("\t") if dash else raw) == delim:
                queue.pop(0)                     # terminator: not code either
            continue                             # body line: data, not code
        code, heredocs = _scan_shell_line(raw)
        kept.append(code)
        queue.extend(heredocs)
    return kept


def _join_continuations(lines):
    """Join backslash-continued lines into logical lines."""
    out = []
    buf = ""
    for ln in lines:
        buf = (buf + " " + ln.strip()).strip() if buf else ln.strip()
        if buf.endswith("\\"):
            buf = buf[:-1].rstrip()
            continue
        if buf:
            out.append(buf)
        buf = ""
    if buf:
        out.append(buf)
    return out


def _normalise_sh(text):
    """Return `text` as a comment-free, whitespace-collapsed shell token stream.

    The dep-stage guard judges the WORDS the stage executes. Both full-line and
    TRAILING comments are dropped (a `#` outside quotes, at the start of a word),
    as are here-doc bodies — none of them is executed — and every whitespace run
    collapses to one space, so upstream may reword or drop any comment, reindent,
    or put `do` on its own line without changing the verdict. What the guard is
    NOT blind to is the pinned banner/gate interface (see dep_stage_region) or a
    genuinely reworded shell.
    """
    return " ".join(" ".join(_shell_code_lines(text)).split())


def dep_stage_region(text):
    """Return the stage-(2) dependency-install region of a router installer, or None.

    The region runs from the line that announces stage (2) (the banner
    `=== (2) dependency packages ...`) up to and INCLUDING that stage's
    `gate_pass deps_installed` line. It is found by the banner and the gate line
    alone — never by a comment, a marker or an exact text block.

    The banner wording and the gate name are a PINNED INTERFACE of this guard:
    both regexes tolerate leading whitespace (a reindent must not change the
    verdict) and a comment line is never taken for the banner, but a REWORDED
    banner or a RENAMED gate is a deliberate re-pin event and fails closed here
    (region is None) rather than being guessed at.
    """
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue                     # a comment cannot announce the stage
        if DEP_STAGE_BANNER_RE.search(line):
            start = i
            break
    if start is None:
        return None
    for j in range(start, len(lines)):
        if DEP_STAGE_END_RE.match(lines[j]):
            return "\n".join(lines[start:j + 1])
    return None


def _ref(name):
    """A shell expansion of `name`: `$name` or `${name}` (both spellings)."""
    return r"(?:\$\{%s\}|\$%s\b)" % (name, name)


# A shell WORD (no separator) that contains a $ref: quotes, an `x`-prefix and
# brace forms are all accepted, because they are all the same comparison.
_REF = r"[^\s;|&()]*\$\{?%s\}?[^\s;|&()]*"

_CMD_START_RE = re.compile(
    r"(?:^|[;&|]\s*|(?:^|\s)!\s*"
    r"|\b(?:if|elif|while|until|then|else|do)\s+!?\s*)$")
_APK_ADD_RE = re.compile(r"\bapk\s+add\b")
# `[ "$rc" != 0 ]` / `[ "${rc}" -ne "0" ]` — the gate on the captured status.
_GATE_TEST_RE = re.compile(
    r"\[\s*\"?\$\{?(\w+)\}?\"?\s*(?:!=|-ne)\s*\"?0\"?\s*\]")
# `if apk add …; then …; else rc=$?; fi` — an else-branch capture (F3): no `||`,
# but still apk's own status, from apk's own command.
_IF_ELSE_CAPTURE_RE = re.compile(
    r"\bif\s+apk\s+add\b[^;]*;?\s*then\b.*?\belse\s+(\w+)=\$\?")


def _command_end(text, start):
    """Offset of the end of the simple command that begins at `start`."""
    i, n = start, len(text)
    sq = dq = False
    while i < n:
        ch = text[i]
        if ch == "\\" and not sq:
            i += 2
            continue
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif not sq and not dq and ch in ";|&":
            return i
        i += 1
    return n


def _apk_add_commands(logical):
    """The REAL `apk add` commands of a stage: [(args, captured_rc_var), ...].

    A command is a word-initial `apk add` — at the start of a logical line, after
    a separator (`;`, `&&`, `||`, `|`) or after a keyword (`if`, `then`, `do`,
    `else`, `elif`, `while`, `until`), optionally negated by `!`. An `apk add`
    that is only MENTIONED — inside a string, e.g.
    `apk_deps_cmd="apk add … $dep_files"`, or echoed to the log — is not a
    command and cannot stand in for one.

    `captured_rc_var` is the variable that captures THIS command's own status
    (`apk add … || rc=$?`, or `rc=$?` on the very next statement), or None.
    """
    cmds = []
    for idx, line in enumerate(logical):
        for m in _APK_ADD_RE.finditer(line):
            if not _CMD_START_RE.search(line[:m.start()]):
                continue                            # a mention, not a command
            end = _command_end(line, m.end())
            tail = line[end:]
            cap = re.match(r"\s*(?:\|\||;)\s*(\w+)=\$\?", tail)
            var = cap.group(1) if cap else None
            if var is None and idx + 1 < len(logical):
                nxt = re.match(r"\s*(\w+)=\$\?\s*;?\s*$", logical[idx + 1])
                var = nxt.group(1) if nxt else None
            cmds.append((line[m.end():end], var))
    return cmds


def _has_glob(args):
    """True if an UNQUOTED `*`/`?` glob sits in an argument list.

    A glob is not a closure: `apk add … "$PKG_DIR"/*.apk` sweeps the package
    under test back in and defeats the exclusion, while the (dead) loop still
    looks compliant.
    """
    sq = dq = False
    i, n = 0, len(args)
    while i < n:
        ch = args[i]
        if ch == "\\":
            i += 2
            continue
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif not sq and not dq and ch in "*?":
            return True
        i += 1
    return False


def _excludes_package_under_test(body, var):
    """True if the $STAGED_APKS loop body rules out the package under test.

    Any correct spelling is accepted: `[ "$f" != "$PKG_APK" ]`,
    `[ "$f" = "$PKG_APK" ] && continue`, `test …`, `case "$f" in "$PKG_APK")
    continue`, and the `${VAR}` brace forms.
    """
    v = re.escape(var)
    neq = re.compile(r"(?:\[|\btest\b)\s+%s\s+(?:!=|-ne)\s+%s"
                     % (_REF % v, _REF % "PKG_APK"))
    eq = re.compile(r"(?:\[|\btest\b)\s+%s\s+(?:==|=)\s+%s"
                    % (_REF % v, _REF % "PKG_APK"))
    case_word = re.compile(r"\bcase\s+%s\s+in\b" % (_REF % v))
    case_arm = re.compile(r"%s\s*\)\s*(?:continue\b|;)" % (_REF % "PKG_APK"))
    if neq.search(body):
        return True
    if eq.search(body) and re.search(r"\bcontinue\b", body):
        return True
    if case_word.search(body) and case_arm.search(body) \
            and re.search(r"\bcontinue\b", body):
        return True
    return False


def _dep_stage_offers_closure(region):
    """Judge the stage-(2) region text. Returns (ok, why_not).

    `why_not` is a human-readable reason on failure so the guard can say what it
    expected and what it found. The things it asserts, all by behaviour:

      1. the package list is built from the WHOLE staged set (`for ... in
         $STAGED_APKS`) and NOT from the top-level deps, excluding the package
         under test (stage (3) installs it on its own, after the keepalive
         assertion, so the no-brick ordering is unchanged);
      2. the REAL `apk add` COMMAND — the one the stage executes, not a mention
         in a string, an inline comment or a here-doc — is offered that
         loop-built list, and is NOT offered the top-level dep names or an
         unquoted `*.apk` glob (a glob sweeps the package under test back in and
         defeats the exclusion);
      3. the gate reports apk's OWN rc, captured from THAT command (`|| rc=$?`,
         an `else`-branch capture, or an assignment on the next statement), not
         `$?` read inside `if !` (which is the NEGATION's status, 0).
    """
    logical = _join_continuations(_shell_code_lines(region))
    norm = _normalise_sh(region)

    # (a) it must not still enumerate the top-level deps instead of the closure.
    for top in ("REQUIRED_DEPS", "STUB_OK_DEPS"):
        if re.search(r"\bfor\s+\w+\s+in\s+" + _ref(top), norm):
            return False, ("it still enumerates $%s, i.e. it names only the "
                           "top-level deps rather than the whole staged "
                           "closure" % top)

    # (b) the file list must be built from the whole staged set ...
    loop = re.search(r"\bfor\s+(\w+)\s+in\s+" + _ref("STAGED_APKS"), norm)
    if not loop:
        return False, ("it never iterates $STAGED_APKS, so it cannot offer the "
                       "whole staged closure to apk")
    var = loop.group(1)
    done = norm.find("done", loop.end())
    body = norm[loop.end():done if done != -1 else len(norm)]
    # ... excluding the package under test (installed separately by stage (3)).
    if not _excludes_package_under_test(body, var):
        return False, ("its $STAGED_APKS loop variable (%s) is never compared "
                       "against \"$PKG_APK\", so the package under test is not "
                       "excluded from the dependency transaction" % var)
    # ... and the list variable the loop BUILDS is what apk must be offered.
    acc = re.search(r"(?<![\w$])(\w+)=[^;|&]*?" + _ref(var), body)
    list_var = acc.group(1) if acc else None
    offered = [r for r in (list_var, "STAGED_APKS") if r]

    # (c) the REAL apk add command(s): at least one must exist, and every one the
    #     stage executes must be offered the closure and nothing else.
    cmds = _apk_add_commands(logical)
    if not cmds:
        return False, ("it never runs an `apk add` command, so nothing is ever "
                       "offered the staged closure (a `|| rc=$?` attached to "
                       "some other command is not an apk install)")
    for args, _var in cmds:
        for top in ("REQUIRED_DEPS", "STUB_OK_DEPS"):
            if re.search(_ref(top), args):
                return False, ("the `apk add` command it runs is offered $%s "
                               "instead of the whole staged closure — that is "
                               "the stage that refuses on a fresh box" % top)
        if _has_glob(args):
            return False, ("the `apk add` command it runs is offered an "
                           "unquoted glob, which sweeps in the package under "
                           "test and defeats its exclusion")
        if not any(re.search(_ref(r), args) for r in offered):
            return False, ("the `apk add` command it runs is not offered the "
                           "list the $STAGED_APKS loop builds (%s), so the loop "
                           "is dead and the closure never reaches apk"
                           % (list_var or loop.group(1)))

    # (d) the gate must report apk's OWN rc, captured from that command ...
    captures = set(v for _a, v in cmds if v)
    for m in _IF_ELSE_CAPTURE_RE.finditer(norm):
        captures.add(m.group(1))
    if not captures:
        return False, ("it does not capture apk's own status from the apk add "
                       "command (`|| <rc>=$?`, an `else` branch, or an "
                       "assignment on the next statement)")
    # ... it must not read `$?` inside `if ! cmd` (that is the negation's 0) ...
    if re.search(r"\bif\s+!\s*apk\s+add\b", norm):
        return False, ("its apk invocation is still wrapped in `if !`, so the "
                       "only status it can read is the negation's")
    # ... and the gate must test and REPORT that captured status.
    gates = [m.group(1) for m in _GATE_TEST_RE.finditer(norm)]
    rc = next((g for g in gates if g in captures), None)
    if rc is None:
        return False, ("it captures %s but never gates on it"
                       % (", ".join(sorted(captures)) or "nothing"))
    if not any(re.search(r"\bgate_fail\b", ln) and re.search(_ref(rc), ln)
               for ln in logical):
        return False, ("its failure report does not print the captured rc (%s)"
                       % rc)
    return True, ""


def guard_router_dep_stage(bundle_dir):
    """Fail the build CLOSED unless the shipped router-side DEPENDENCY stage
    offers the WHOLE staged closure to apk and reports apk's own rc.

    This is a GUARD, not a rewrite: it never modifies install-router.sh, so on
    success the shipped file is BYTE-IDENTICAL to the pinned source. It returns a
    one-line note for the installer provenance block, or "" when the bundle
    carries no router-side installer, or the file is a fixture/synthetic driver
    rather than the OFFLINE-BUNDLE-2 router half (no fingerprint) — those are
    passed through untouched.

    Stage (2) of install-router.sh hands apk the dependency files BY PATH, and
    apk-tools 3 resolves a transaction from the files NAMED on the command line
    plus the installed DB, and from nothing else. With --no-network a WAN-less
    box has no index to fall back on, so every dependency of a named package that
    is not itself named is `(no such package)` and apk refuses the WHOLE
    transaction. The bundle's closure is complete (the builder resolved and
    staged all of it, and gate `bundle_closure` asserts the required deps are
    present); a stage that names only REQUIRED_DEPS + STUB_OK_DEPS simply never
    offered the rest of it, and on a fresh box that is

        REFUSED(7): the offline dependency install failed.

    (An UPGRADE box already has nodogsplash's deps installed, so the transaction
    resolves from the DB and such a stage looks correct — which is why a fresh
    flash was the first box to refuse.) Upstream PR #178 fixed this at the
    source, so the guard passes on the current pin; it fails the build closed on
    any real installer whose stage is not the shape it can guarantee. It judges
    the shell the stage EXECUTES: it is blind to comments (full-line and trailing)
    and to whitespace/indentation, and it locates the real `apk add` command
    rather than a mention of one — but the banner and gate wording are a pinned
    interface, and a genuinely reworded shell is not the same stage.
    """
    path = os.path.join(bundle_dir, ROUTER_INSTALLER_NAME)
    if not os.path.isfile(path):
        return ""
    before = sha256_file(path)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except UnicodeDecodeError as exc:
        raise Fail(
            "the pinned router-side installer %s is not valid UTF-8 (%s), so "
            "this builder cannot read its stage (2) dependency install to guard "
            "it. Refusing to ship a bundle whose dependency stage cannot be "
            "checked; re-check OFFLINE_INSTALLER_REF and re-pin a plain-text "
            "installer." % (ROUTER_INSTALLER_NAME, exc))
    if not all(frag in text for frag in ROUTER_INSTALLER_FINGERPRINT):
        log("%s is not the OFFLINE-BUNDLE-2 router-side installer (no %s); "
            "nothing to guard"
            % (ROUTER_INSTALLER_NAME, ROUTER_INSTALLER_FINGERPRINT[0]))
        return ""

    region = dep_stage_region(text)
    if region is None:
        raise Fail(
            "the pinned router-side installer %s carries the OFFLINE-BUNDLE-2 "
            "fingerprint but has no stage (2) dependency-install region to "
            "guard (looked for a line announcing `(2) dependency packages` and "
            "that stage's `gate_pass deps_installed` line, and found neither). "
            "Refusing to ship a bundle whose dependency stage cannot be shown "
            "to offer apk the whole staged closure: with --no-network apk "
            "resolves a transaction from the files NAMED on the command line "
            "only, so a dep that is not named is `(no such package)` and a "
            "WAN-less fresh box refuses with REFUSED(7). Reconcile %s with this "
            "builder's guard (guard_router_dep_stage) and re-pin "
            "OFFLINE_INSTALLER_REF."
            % (ROUTER_INSTALLER_NAME, ROUTER_INSTALLER_NAME))

    ok, why = _dep_stage_offers_closure(region)
    if not ok:
        raise Fail(
            "the pinned router-side installer %s has a stage (2) dependency "
            "install that does NOT offer the whole staged closure to apk: %s. "
            "Expected the stage to build its package list from the WHOLE staged "
            "set (`for ... in $STAGED_APKS`, excluding the package under test, "
            "which stage (3) installs on its own) and to report apk's OWN rc "
            "(captured from the apk add command, not `$?` inside `if !`). This "
            "builder no longer rewrites the stage — the upstream installer must "
            "carry the fix. Refusing to ship a bundle that refuses on a fresh "
            "box; reconcile %s with the shipped guard and re-pin "
            "OFFLINE_INSTALLER_REF."
            % (ROUTER_INSTALLER_NAME, why, ROUTER_INSTALLER_NAME))

    after = sha256_file(path)
    if after != before:
        raise Fail("the dep-stage guard modified %s (it must never write to the "
                   "installer)" % ROUTER_INSTALLER_NAME)

    pkgs = os.path.join(bundle_dir, "pkgs")
    staged = 0
    if os.path.isdir(pkgs):
        # Recursive, and the package under test is NOT counted: the note says
        # "minus the package under test", so the number must not include it.
        staged = len([n for _root, _dirs, files in os.walk(pkgs)
                      for n in files
                      if n.endswith(".apk")
                      and not n.startswith(ROUTER_PKG_PREFIX)])
    log("router-side dependency stage: %s offers the full staged closure to apk "
        "in one --no-network transaction and reports apk's own rc; shipped "
        "byte-identical to the pin (sha256 %s)"
        % (ROUTER_INSTALLER_NAME, after))
    return ("router: dependency stage offers the FULL staged closure to apk "
            "(%d staged package(s) minus the package under test), rc captured "
            "from apk itself; %s shipped byte-identical to the pin, sha256 %s"
            % (staged, ROUTER_INSTALLER_NAME, after))


def cmd_assemble(args):
    bundle_name = "tollgate-wrt-%s-%s-offline" % (args.pkg_version, _arch_of(args))
    out_dir = os.path.abspath(args.out)
    bundle_dir = os.path.join(out_dir, bundle_name)
    payload = load_payload(args.payload)

    if os.path.isdir(bundle_dir):
        shutil.rmtree(bundle_dir)
    pkgs = os.path.join(bundle_dir, "pkgs")
    os.makedirs(pkgs)

    apks_dir = payload.get("apks_dir") or getattr(args, "apks_dir", "") or ""
    for member in payload["members"]:
        # `path` is recorded when the member is fetched; the fallback keeps a
        # hand-written payload working.
        candidate = member.get("path") or os.path.join(apks_dir, member["file"])
        if not os.path.isfile(candidate):
            raise Fail("bundle member %s is missing on disk (%s)"
                       % (member["file"], candidate))
        got = sha256_file(candidate)
        if got != member["sha256"]:
            raise Fail("bundle member %s changed since it was fetched: %s != %s"
                       % (member["file"], got, member["sha256"]))
        shutil.copy2(candidate, os.path.join(pkgs, member["file"]))

    installer_note = ""
    installer_files = []
    installer = args.installer
    installer_dir = getattr(args, "installer_dir", "")
    if installer and installer_dir:
        raise Fail("pass --installer or --installer-dir, not both")
    if installer_dir:
        # The installer is not a single file: the bundle must also carry its
        # router-side companion (install-router.sh) and the management keepalive
        # seed, or the driver refuses to install. Copy the whole pinned
        # directory so the bundle root matches what the driver looks for.
        src_dir = os.path.abspath(installer_dir)
        if not os.path.isdir(src_dir):
            raise Fail("--installer-dir %s is not a directory" % installer_dir)
        main = os.path.join(src_dir, INSTALLER_NAME)
        if not os.path.isfile(main):
            raise Fail("--installer-dir %s has no %s" % (installer_dir, INSTALLER_NAME))
        for root, dirs, files in os.walk(src_dir):
            dirs.sort()
            for name in sorted(files):
                src = os.path.join(root, name)
                rel = os.path.relpath(src, src_dir)
                dest = os.path.join(bundle_dir, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy2(src, dest)
                os.chmod(dest, os.stat(src).st_mode & 0o777)
                installer_files.append(rel)
        seed_note = repair_keepalive_seed(bundle_dir)
        dep_note = guard_router_dep_stage(bundle_dir)
        installer_note = ("installer (pinned, from OFFLINE-BUNDLE-2 / "
                          "OpenTollGate/physical-router-test-automation "
                          "scripts/offline/): %d file(s), install-offline.sh "
                          "sha256 %s"
                          % (len(installer_files),
                             sha256_file(os.path.join(bundle_dir, INSTALLER_NAME))))
        if seed_note:
            installer_note += "\n" + seed_note
        if dep_note:
            installer_note += "\n" + dep_note
    elif installer:
        if not os.path.isfile(installer):
            raise Fail("--installer %s does not exist" % installer)
        shutil.copy2(installer, os.path.join(bundle_dir, INSTALLER_NAME))
        os.chmod(os.path.join(bundle_dir, INSTALLER_NAME), 0o755)
        installer_files.append(INSTALLER_NAME)
        installer_note = ("install-offline.sh: shipped in this bundle, %s\n"
                          "(OFFLINE-BUNDLE-2, OpenTollGate/physical-router-test-automation)"
                          % sha256_file(os.path.join(bundle_dir, INSTALLER_NAME)))
    elif args.allow_missing_installer:
        installer_note = ("install-offline.sh: **NOT INCLUDED** — this bundle was "
                          "assembled with --allow-missing-installer (OFFLINE-BUNDLE-2 "
                          "had not landed). The release job requires it.")
        warn("assembling WITHOUT install-offline.sh (--allow-missing-installer)")
    else:
        raise Fail("no --installer: a bundle without install-offline.sh is not "
                   "installable (pass --installer <path>, or --allow-missing-installer "
                   "to build a non-shipping bundle)")

    layout = ["pkgs/  (%d packages: the tollgate-wrt package + its closed "
              "dependency set)" % payload["member_count"],
              "MANIFEST.sha256  sha256 of every file in this bundle"]
    layout += ["%s  (installer)" % name for name in
               sorted(n for n in installer_files if os.sep not in n)]
    layout += ["%s" % name for name in
               sorted(n for n in installer_files if os.sep in n)]
    layout.append("README.md  this file")

    readme = os.path.join(bundle_dir, "README.md")
    with open(readme, "w", encoding="utf-8") as fh:
        fh.write(readme_text(payload, args.pkg_version, installer_note, layout))
    log("installer files: %s" % ", ".join(installer_files) if installer_files
        else "installer files: (none)")

    manifest, count = write_manifest(bundle_dir)
    check = subprocess.run(["sha256sum", "--check", "--strict", MANIFEST_NAME],
                           cwd=bundle_dir, capture_output=True, text=True)
    if check.returncode != 0:
        raise Fail("generated MANIFEST does not verify:\n%s%s"
                   % (check.stdout[-2000:], check.stderr[-2000:]))

    tarball = os.path.join(out_dir, bundle_name + ".tar.gz")
    tar_tmp = os.path.join(out_dir, bundle_name + ".tar")
    run(["tar", "--sort=name", "--owner=0", "--group=0", "--numeric-owner",
         "--mtime=@0", "-cf", tar_tmp, "-C", bundle_dir, "."])
    run(["gzip", "-9n", "-f", tar_tmp])
    # The archive must carry the documented layout at its ROOT.
    with tarfile.open(tarball) as tar:
        names = tar.getnames()
    rooted = set()
    for name in names:
        rooted.add(name[2:] if name.startswith("./") else name)
        rooted.add(name.rstrip("/"))
    required = ["pkgs", "MANIFEST.sha256", "README.md"]
    if not args.allow_missing_installer:
        required.append(INSTALLER_NAME)
    required += [n for n in installer_files if os.sep not in n]
    for expected in required:
        if expected not in rooted:
            raise Fail("archive %s is missing %s (has: %s)"
                       % (tarball, expected, ", ".join(sorted(rooted)[:12])))
    members = sorted(n for n in names if n.endswith(".apk"))
    if len(members) != payload["member_count"]:
        raise Fail("archive carries %d .apk files, expected %d"
                   % (len(members), payload["member_count"]))

    log("")
    log("bundle:   %s" % bundle_dir)
    log("manifest: %s (%d entries)" % (manifest, count))
    log("tarball:  %s (%d bytes)" % (tarball, os.path.getsize(tarball)))
    log("tarball sha256: %s" % sha256_file(tarball))
    log("members:  %d  base-image-provided: %d  stubbed: %d"
        % (payload["member_count"], len(payload["base_provided"]),
           len(payload["stubbed"])))
    return 0


def _arch_of(args):
    if args.arch:
        return args.arch
    payload = load_payload(args.payload)
    return payload["arch"]


def load_payload(path):
    if not path:
        raise Fail("assemble needs --payload (from `fetch`)")
    if not os.path.exists(path):
        raise Fail("no payload at %s: run `fetch` first" % path)
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def cmd_manifest(args):
    directory = os.path.abspath(args.dir)
    if not os.path.isdir(directory):
        raise Fail("not a directory: %s" % directory)
    manifest, count = write_manifest(directory)
    log("wrote %s (%d entries)" % (manifest, count))
    return 0


def cmd_build(args):
    cache_dir = os.path.abspath(args.cache_dir)
    plan_path = os.path.join(cache_dir, "plan.json")
    payload_path = os.path.join(cache_dir, "payload.json")

    plan_args = argparse.Namespace(**vars(args))
    plan_args.out = plan_path
    rc = cmd_plan(plan_args)
    if rc != 0:
        return rc

    fetch_args = argparse.Namespace(**vars(args))
    fetch_args.plan = plan_path
    fetch_args.out = payload_path
    rc = cmd_fetch(fetch_args)
    if rc != 0:
        return rc

    args.payload = payload_path
    return cmd_assemble(args)


# --------------------------------------------------------------------------
def main(argv):
    parser = argparse.ArgumentParser(
        prog="offline-bundle.py",
        description="build the per-arch tollgate-wrt offline dependency bundle",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--cache-dir", default="offline-cache",
                       help="working cache (indexes, apks, plan, payload)")
        p.add_argument("--release", default=DEFAULT_RELEASE,
                       help="OpenWrt release, e.g. 25.12.5")
        p.add_argument("--arch", default=DEFAULT_ARCH,
                       help="package arch, e.g. aarch64_cortex-a53")
        p.add_argument("--target", default=DEFAULT_TARGET,
                       help="target/subtarget, e.g. mediatek-filogic")
        p.add_argument("--target-path", default="",
                       help="downloads URL path for the target, e.g. "
                            "mediatek/filogic (default: derived from --target)")
        p.add_argument("--downloads-base", default=DOWNLOADS_BASE)
        p.add_argument("--apk-bin", default="",
                       help="apk-tools 3 binary (default: $APK_BIN, PATH, or a "
                            "pinned sha256-verified apk-tools-static)")

    plan_p = sub.add_parser("plan", help="resolve the dependency closure")
    common(plan_p)
    plan_p.add_argument("--pkg-version", default="")
    plan_p.add_argument("--profile", default="",
                        help="device profile for base-image packages "
                             "(default: default_packages only)")
    plan_p.add_argument("--seeds", default=DEFAULT_SEEDS)
    plan_p.add_argument("--tollgate-apk", default="",
                        help="the built tollgate-wrt .apk: its own depends are "
                             "added to the seeds")
    plan_p.add_argument("--base-packages", default="",
                        help="file of base-image package names (one per line)")
    plan_p.add_argument("--kmods-dir", default="")
    plan_p.add_argument("--feeds", default="")
    plan_p.add_argument("--allow-stub", default="")
    plan_p.add_argument("--out", default="")
    plan_p.add_argument("--refresh", action="store_true")
    plan_p.set_defaults(func=cmd_plan)

    fetch_p = sub.add_parser("fetch", help="download and verify member .apks")
    common(fetch_p)
    fetch_p.add_argument("--plan", default="")
    fetch_p.add_argument("--tollgate-apk", default="")
    fetch_p.add_argument("--out", default="")
    fetch_p.add_argument("--refresh", action="store_true")
    fetch_p.set_defaults(func=cmd_fetch)

    asm_p = sub.add_parser("assemble", help="write bundle dir + MANIFEST + tarball")
    asm_p.add_argument("--payload", default="")
    asm_p.add_argument("--apks-dir", default="")
    asm_p.add_argument("--arch", default="")
    asm_p.add_argument("--pkg-version", required=True)
    asm_p.add_argument("--installer", default="",
                       help="a single install-offline.sh for the bundle root")
    asm_p.add_argument("--installer-dir", default="",
                       help="the pinned installer DIRECTORY (scripts/offline/): "
                            "every file in it is copied into the bundle root, "
                            "because the driver needs install-router.sh and the "
                            "keepalive template too")
    asm_p.add_argument("--allow-missing-installer", action="store_true")
    asm_p.add_argument("--out", required=True)
    asm_p.set_defaults(func=cmd_assemble)

    man_p = sub.add_parser("manifest", help="write MANIFEST.sha256 for a directory")
    man_p.add_argument("--dir", required=True)
    man_p.set_defaults(func=cmd_manifest)

    build_p = sub.add_parser("build", help="plan + fetch + assemble")
    common(build_p)
    build_p.add_argument("--pkg-version", required=True)
    build_p.add_argument("--profile", default="")
    build_p.add_argument("--seeds", default=DEFAULT_SEEDS)
    build_p.add_argument("--tollgate-apk", default="")
    build_p.add_argument("--base-packages", default="")
    build_p.add_argument("--kmods-dir", default="")
    build_p.add_argument("--feeds", default="")
    build_p.add_argument("--allow-stub", default="")
    build_p.add_argument("--out", required=True)
    build_p.add_argument("--installer", default="")
    build_p.add_argument("--installer-dir", default="")
    build_p.add_argument("--allow-missing-installer", action="store_true")
    build_p.add_argument("--refresh", action="store_true")
    build_p.set_defaults(func=cmd_build)

    args = parser.parse_args(argv)
    if not hasattr(args, "plan"):
        args.plan = ""
    if not hasattr(args, "payload"):
        args.payload = ""
    try:
        return args.func(args)
    except Fail as exc:
        fail(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
