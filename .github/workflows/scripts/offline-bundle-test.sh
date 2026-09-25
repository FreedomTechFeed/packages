#!/usr/bin/env bash
#
# Self-test for offline-bundle.py — the per-arch offline dependency bundle that
# lets a router with NO uplink install tollgate-wrt from the package lane.
#
# Three groups, one per way this feature can lie to us:
#
#   A. the closure resolver, on a small FIXTURE index. A complete closure must
#      pass; a dependency nothing provides must be REPORTED BY NAME and fail
#      closed; a stale virtual dependency (libpthread, which no OpenWrt 25.12
#      feed needs but published packages still declare) is stub-able, while a
#      RUNTIME dependency (iptables-nft) never is — nodogsplash 5.0.2 execs
#      `iptables --version` at startup, so a stub for it crash-loops the daemon.
#   B. the bundle itself: an intact bundle verifies against MANIFEST.sha256, one
#      tampered byte fails, the manifest covers the tollgate-wrt package, and a
#      bundle with no install-offline.sh refuses to be assembled.
#   C. the release ORDERING: the workflow must build the offline bundle BEFORE
#      it signs SHA256SUMS, and the bundle's asset name must be in the expected
#      asset set (otherwise the signed manifest does not cover it).
#
# Group C is checked against a MUTATED copy of the real workflow as a negative
# control, so the assertion cannot pass vacuously:
#   `order_ok` on the real workflow      -> must PASS
#   `order_ok` on the mutated workflow   -> must FAIL
#
# Run locally:  bash .github/workflows/scripts/offline-bundle-test.sh
# Offline: groups A, B and C are hermetic (no network, no apk needed).
#
# ---------------------------------------------------------------------------
# Evidence — both runs executed 2026-09-25 on this branch. The RED run points
# the suite at a copy of the builder with four guards removed (an unresolved
# dependency no longer fails the plan, a bundle may be assembled without
# install-offline.sh, MANIFEST.sha256 stops covering pkgs/, and a member whose
# bytes changed after fetching is no longer refused):
#
# RED   $ OFFLINE_BUNDLE_TEST_SUBJECT=<guard-less copy> bash offline-bundle-test.sh
#   FAIL missing-dependency fails closed and names it
#   FAIL runtime-dep-absent: a missing RUNTIME dependency is never stubbed
#   FAIL a constrained stale virtual dep is refused (a stub cannot satisfy it)
#   FAIL manifest does not cover the tollgate-wrt package
#   FAIL tampered byte fails the manifest check
#   FAIL a member whose bytes changed after fetching is refused
#   24 passed, 6 failed        <- rc=1
#
# GREEN $ bash .github/workflows/scripts/offline-bundle-test.sh
#   30 passed, 0 failed        <- rc=0
#
# The ordering assertions (group C) also ran RED before release-publish.yml was
# wired: "release workflow does not build the offline bundle before signing
# SHA256SUMS", "the publish job does not depend on the offline-bundle job" and
# "the signing asset set does not contain the offline bundle" were the three
# failures of that first run, and the mutated-workflow control separately proves
# the ordering assertion is not vacuous.
# ---------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SCRIPT="${OFFLINE_BUNDLE_TEST_SUBJECT:-$HERE/offline-bundle.py}"
ASSETS_PY="$HERE/release-assets.py"
RELEASE_WF="${OFFLINE_BUNDLE_TEST_WORKFLOW:-$ROOT/.github/workflows/release-publish.yml}"
VERSION="0.6.0_alpha4_pre17"
ARCH="aarch64_cortex-a53"
BUNDLE_ASSET="tollgate-wrt-${VERSION}-${ARCH}-offline.tar.gz"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# --------------------------------------------------------------- A: fixtures
# A deliberately small index: two feeds, a `provides` indirection, a version
# constrained dependency on the virtual `kernel`, a base-image package, a stale
# virtual dependency (libpthread) with no provider anywhere, and jq.
FIX="$WORK/fixture/idx"
mkdir -p "$FIX"

cat > "$FIX/base.txt" <<'EOF'
packages: # 2 items
  - name: libc
    version: 1.2.5-r5
    arch: aarch64_cortex-a53
  - name: zlib
    version: 1.3-r1
    arch: aarch64_cortex-a53
EOF

cat > "$FIX/packages.txt" <<'EOF'
packages: # 2 items
  - name: jq
    version: 1.8.1-r2
    arch: aarch64_cortex-a53
    depends: # 1 items
      - libc
  - name: libmicrohttpd
    version: 1.0.2-r1
    arch: aarch64_cortex-a53
    provides: # 1 items
      - libmicrohttpd-no-ssl
EOF

cat > "$FIX/routing.txt" <<'EOF'
packages: # 1 items
  - name: nodogsplash
    version: 5.0.2-r2
    arch: aarch64_cortex-a53
    depends: # 3 items
      - iptables-nft
      - libmicrohttpd-no-ssl
      - libpthread
EOF

cat > "$FIX/target.txt" <<'EOF'
packages: # 3 items
  - name: iptables-nft
    version: 1.8.10-r3
    arch: aarch64_cortex-a53
    depends: # 2 items
      - libxtables
      - kernel=6.12.94~5a6c1f71-r1
  - name: libxtables
    version: 1.8.10-r3
    arch: aarch64_cortex-a53
    depends: # 1 items
      - libc
  - name: kernel
    version: 6.12.94~5a6c1f71-r1
    arch: aarch64_cortex-a53
EOF

printf 'packages: # 0 items\n' > "$FIX/kmods.txt"
printf '# base image packages\nlibc\nkmod-nft-core\n' > "$WORK/base-packages.txt"

# A runtime dependency with NO provider in any feed: the same index minus the
# target feed, which is where iptables-nft lives.
FIX_NOTARGET="$WORK/fixture-notarget/idx"
mkdir -p "$FIX_NOTARGET"
cp "$FIX/base.txt" "$FIX/packages.txt" "$FIX/routing.txt" "$FIX_NOTARGET/"

plan() { # plan <cache-dir> <seeds> [extra args...]
  local cache="$1" seeds="$2"; shift 2
  python3 "$SCRIPT" plan --cache-dir "$cache" --release 25.12.5 --arch "$ARCH" \
    --target mediatek-filogic --kmods-dir 6.12.94-1-fake \
    --base-packages "$WORK/base-packages.txt" --seeds "$seeds" "$@" \
    > "$WORK/plan.log" 2>&1
}

# ---- A1: a complete closure resolves, through a `provides` name ----
if plan "$WORK/fixture" "nodogsplash,jq" --out "$WORK/plan.json"; then
  pass "complete closure resolves"
else
  fail "complete closure: $(tail -n2 "$WORK/plan.log")"
fi
python3 - "$WORK/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
names = sorted(m["name"] for m in plan["members"])
checks = [
    ("closure is closed", plan["closure_closed"] is True),
    ("member set", names == ["iptables-nft", "jq", "libmicrohttpd", "libxtables", "nodogsplash"]),
    ("`provides` name resolved to its provider",
     any(m["name"] == "libmicrohttpd" for m in plan["members"])),
    ("version-constrained dep on the virtual kernel is base-image-provided",
     [e["name"] for e in plan["base_provided"]] == ["kernel", "libc"]),
    ("stale virtual dep classified stub-able",
     [e["name"] for e in plan["stubbed"]] == ["libpthread"]),
]
for label, ok in checks:
    print(("ok   " if ok else "FAIL ") + label)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
if [ $? -eq 0 ]; then PASS=$((PASS + 5)); else FAIL=$((FAIL + 5)); fi

# ---- A2: a dependency nothing provides is REPORTED BY NAME and fails closed --
cat > "$FIX/routing.txt" <<'EOF'
packages: # 2 items
  - name: nodogsplash
    version: 5.0.2-r2
    arch: aarch64_cortex-a53
    depends: # 3 items
      - iptables-nft
      - libmicrohttpd-no-ssl
      - libpthread
  - name: brokenpkg
    version: 1.0-r1
    arch: aarch64_cortex-a53
    depends: # 2 items
      - nodogsplash
      - ghost-pkg
EOF
if plan "$WORK/fixture" "brokenpkg" --out "$WORK/plan-broken.json"; then
  fail "missing-dependency fails closed and names it"
else
  if grep -q 'ghost-pkg' "$WORK/plan.log"; then
    pass "missing-dependency fails closed and names it"
  else
    fail "missing-dependency failed without naming ghost-pkg: $(tail -n1 "$WORK/plan.log")"
  fi
fi
if grep -q 'brokenpkg' "$WORK/plan.log"; then
  pass "missing-dependency names the requiring member"
else
  fail "missing-dependency did not name the member that requires it: $(tail -n1 "$WORK/plan.log")"
fi

# ---- A3: a stale virtual dep is stub-able; a RUNTIME dep never is ----
# With the target feed present, iptables-nft is a real package and is BUNDLED.
if plan "$WORK/fixture" "nodogsplash" --out "$WORK/plan-runtime.json"; then
  if python3 -c "
import json,sys
plan=json.load(open('$WORK/plan-runtime.json'))
member=[m for m in plan['members'] if m['name']=='iptables-nft']
stub=[e['name'] for e in plan['stubbed']]
sys.exit(0 if member and 'iptables-nft' not in stub else 1)"; then
    pass "a real runtime dependency is bundled, not stubbed"
  else
    fail "iptables-nft was not bundled as a real package"
  fi
else
  fail "runtime-dep plan failed: $(tail -n1 "$WORK/plan.log")"
fi
# Without the target feed nothing provides iptables-nft: it must NOT be stubbed.
if plan "$WORK/fixture-notarget" "nodogsplash" --out "$WORK/plan-notarget.json" \
     --feeds base,packages,routing; then
  fail "runtime-dep-absent: a missing RUNTIME dependency is never stubbed"
else
  if grep -q 'iptables-nft' "$WORK/plan.log"; then
    pass "runtime-dep-absent fails closed, naming iptables-nft"
  else
    fail "runtime-dep-absent failed without naming iptables-nft: $(tail -n1 "$WORK/plan.log")"
  fi
fi

# ---- A4: a version constraint on an unprovided (stale virtual) dep fails -----
cat > "$FIX_NOTARGET/routing.txt" <<'EOF'
packages: # 1 items
  - name: constrainingpkg
    version: 1.0-r1
    arch: aarch64_cortex-a53
    depends: # 1 items
      - libpthread>=1.2
EOF
if plan "$WORK/fixture-notarget" "constrainingpkg" --out "$WORK/plan-constraint.json" \
     --feeds base,packages,routing; then
  fail "a constrained stale virtual dep is refused (a stub cannot satisfy it)"
else
  pass "a constrained stale virtual dep is refused (a stub cannot satisfy it)"
fi

# ------------------------------------------------------------- B: the bundle
mkdir -p "$WORK/bundle-src"
for name in jq-1.8.1-r2 nodogsplash-5.0.2-r2 libc-1.2.5-r5; do
  printf 'fixture apk %s\n' "$name" > "$WORK/bundle-src/$name.apk"
done
printf 'tollgate package\n' > "$WORK/bundle-src/tollgate-wrt_${VERSION}_${ARCH}.apk"
printf '#!/bin/sh\necho fixture installer\n' > "$WORK/bundle-src/install-offline.sh"
chmod +x "$WORK/bundle-src/install-offline.sh"

python3 - "$WORK/bundle-src" "$WORK/payload.json" "$ARCH" <<'PY'
import hashlib, json, os, sys
src, out, arch = sys.argv[1], sys.argv[2], sys.argv[3]


def sha(name):
    with open(os.path.join(src, name), "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


members = []
for name, kind in (("tollgate-wrt_0.6.0_alpha4_pre17_%s.apk" % arch, "tollgate-package"),
                   ("nodogsplash-5.0.2-r2.apk", "package"),
                   ("jq-1.8.1-r2.apk", "package"),
                   ("libc-1.2.5-r5.apk", "package")):
    members.append({"name": name.replace(".apk", ""), "kind": kind, "file": name,
                    "sha256": sha(name), "size": os.path.getsize(os.path.join(src, name)),
                    "path": os.path.join(src, name)})
json.dump({"schema": 1, "release": "25.12.5", "arch": arch,
           "target": "mediatek-filogic", "profile": "glinet_gl-mt3000",
           "members": members, "member_count": len(members),
           "base_provided": [{"name": "libc", "required_by": "jq"}],
           "stubbed": [], "closure_closed": True,
           "apks_dir": src}, open(out, "w"), indent=2)
PY

assemble() { # assemble <out-dir> [extra args...]
  python3 "$SCRIPT" assemble --payload "$WORK/payload.json" --arch "$ARCH" \
    --pkg-version "$VERSION" --out "$1" "${@:2}" > "$WORK/assemble.log" 2>&1
}

if assemble "$WORK/out" --installer "$WORK/bundle-src/install-offline.sh"; then
  pass "bundle assembles from a fixture payload"
else
  fail "bundle assembly: $(tail -n2 "$WORK/assemble.log")"
fi

BUNDLE="$WORK/out/tollgate-wrt-${VERSION}-${ARCH}-offline"
if (cd "$BUNDLE" && sha256sum --check --strict MANIFEST.sha256 >/dev/null 2>&1); then
  pass "an intact bundle verifies against MANIFEST.sha256"
else
  fail "an intact bundle does not verify against MANIFEST.sha256"
fi

if grep -q "pkgs/tollgate-wrt_${VERSION}_${ARCH}.apk" "$BUNDLE/MANIFEST.sha256"; then
  pass "manifest covers the tollgate-wrt package"
else
  fail "manifest does not cover the tollgate-wrt package"
fi
if grep -q 'install-offline.sh' "$BUNDLE/MANIFEST.sha256" && grep -q 'README.md' "$BUNDLE/MANIFEST.sha256"; then
  pass "manifest covers the installer and the README"
else
  fail "manifest does not cover the installer and the README"
fi
if grep -q 'MANIFEST.sha256' "$BUNDLE/MANIFEST.sha256"; then
  fail "manifest lists itself (self-covering manifests cannot verify)"
else
  pass "manifest does not list itself"
fi

printf 'x' >> "$BUNDLE/pkgs/jq-1.8.1-r2.apk"
if (cd "$BUNDLE" && sha256sum --check --strict MANIFEST.sha256 >/dev/null 2>&1); then
  fail "tampered byte fails the manifest check"
else
  pass "one tampered byte fails the manifest check"
fi

# A bundle with no installer is not installable and must not be produced.
if assemble "$WORK/out-noinstaller"; then
  fail "bundle without install-offline.sh refuses to assemble"
else
  if grep -q 'install-offline.sh' "$WORK/assemble.log"; then
    pass "bundle without install-offline.sh refuses to assemble, naming it"
  else
    fail "assembly failed without naming install-offline.sh: $(tail -n1 "$WORK/assemble.log")"
  fi
fi

# The explicit escape hatch exists (OFFLINE-BUNDLE-2 had not landed when this
# was written) and MUST change the behaviour and the README.
if assemble "$WORK/out-noplaceholder" --allow-missing-installer; then
  if grep -q 'NOT INCLUDED' "$WORK/out-noplaceholder/tollgate-wrt-${VERSION}-${ARCH}-offline/README.md"; then
    pass "--allow-missing-installer assembles and records the omission in the README"
  else
    fail "--allow-missing-installer assembled but the README does not record the omission"
  fi
else
  fail "--allow-missing-installer: $(tail -n2 "$WORK/assemble.log")"
fi

# The installer is a DIRECTORY, not a file: the driver (OFFLINE-BUNDLE-2) also
# needs install-router.sh and the management keepalive seed, and refuses to
# install a bundle without them. --installer-dir must carry all of it.
mkdir -p "$WORK/installer-src/templates"
printf '#!/bin/sh\necho driver\n' > "$WORK/installer-src/install-offline.sh"
printf '#!/bin/sh\necho router side\n' > "$WORK/installer-src/install-router.sh"
printf 'trustedmac + allow tcp port 22\n' > "$WORK/installer-src/templates/99z-mgmt-keepalive"
chmod +x "$WORK/installer-src/install-offline.sh" "$WORK/installer-src/install-router.sh"
if assemble "$WORK/out-dir" --installer-dir "$WORK/installer-src"; then
  BUNDLE_DIR_CASE="$WORK/out-dir/tollgate-wrt-${VERSION}-${ARCH}-offline"
  missing=""
  for member in install-offline.sh install-router.sh templates/99z-mgmt-keepalive; do
    [ -f "$BUNDLE_DIR_CASE/$member" ] || missing="$missing $member"
  done
  if [ -z "$missing" ]; then
    pass "--installer-dir carries the driver's companions (install-router.sh + keepalive seed)"
  else
    fail "--installer-dir did not carry:$missing"
  fi
  if grep -c 'install-router.sh\|templates/99z-mgmt-keepalive' "$BUNDLE_DIR_CASE/MANIFEST.sha256" | grep -qx 2; then
    pass "the manifest covers the installer's companion files"
  else
    fail "the manifest does not cover the installer's companions"
  fi
  if tar -tzf "$WORK/out-dir/tollgate-wrt-${VERSION}-${ARCH}-offline.tar.gz" | grep -F './templates/99z-mgmt-keepalive' >/dev/null; then
    pass "the archive carries the keepalive seed"
  else
    fail "the archive does not carry the keepalive seed"
  fi
else
  fail "--installer-dir assembly: $(tail -n2 "$WORK/assemble.log")"
fi
if assemble "$WORK/out-dir-noinstaller" --installer-dir "$WORK/payload.json"; then
  fail "an --installer-dir without install-offline.sh is refused"
else
  pass "an --installer-dir without install-offline.sh is refused"
fi

# A payload member whose bytes changed since it was fetched must not be shipped.
python3 - "$WORK/payload-bad.json" "$WORK/payload.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[2]))
plan["members"][1]["sha256"] = "0" * 64
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
if python3 "$SCRIPT" assemble --payload "$WORK/payload-bad.json" --arch "$ARCH" \
      --pkg-version "$VERSION" --out "$WORK/out-bad" \
      --installer "$WORK/bundle-src/install-offline.sh" > "$WORK/assemble-bad.log" 2>&1; then
  fail "a member whose bytes changed after fetching is refused"
else
  pass "a member whose bytes changed after fetching is refused"
fi

# The archive carries the documented layout at its ROOT.
TARBALL="$WORK/out/tollgate-wrt-${VERSION}-${ARCH}-offline.tar.gz"
if [ -f "$TARBALL" ]; then
  names="$(tar -tzf "$TARBALL")"
  for entry in './pkgs/' './MANIFEST.sha256' './README.md' './install-offline.sh'; do
    echo "$names" | grep -F -x -e "$entry" >/dev/null || { fail "archive lacks $entry"; break; }
  done
  if echo "$names" | grep -F -x -e './pkgs/' >/dev/null \
     && echo "$names" | grep -F -x -e './install-offline.sh' >/dev/null; then
    pass "tar.gz carries pkgs/, MANIFEST.sha256, README.md and install-offline.sh at its root"
  fi
else
  fail "assembly produced no ${BUNDLE_ASSET}"
fi

# ------------------------------------------------------ C: release ordering
if python3 "$ASSETS_PY" expected "$VERSION" | grep -F -x -q "$BUNDLE_ASSET"; then
  pass "the signed manifest's expected asset set contains the offline bundle"
else
  fail "expected asset set does not contain $BUNDLE_ASSET (its hash would not be signed)"
fi

if python3 - "$ASSETS_PY" "$VERSION" <<'PY'
import json, subprocess, sys
assets_py, version = sys.argv[1], sys.argv[2]
matrix = json.loads(subprocess.run(["python3", assets_py, "offline-matrix"],
                                   capture_output=True, text=True, check=True).stdout)
expected = subprocess.run(["python3", assets_py, "expected-offline", version],
                          capture_output=True, text=True, check=True).stdout.split()
sys.exit(0 if len(matrix["include"]) == len(expected) and expected else 1)
PY
then
  pass "the offline bundle build matrix and its expected asset list agree"
else
  fail "the offline bundle build matrix and its expected asset list disagree"
fi

# The ordering check itself, factored out so it can be pointed at a MUTATED
# workflow as a negative control.
order_ok() { # order_ok <workflow-file>
  local f="$1" dl sign
  dl=$(grep -n 'name: Download the offline bundles' "$f" | head -n1 | cut -d: -f1)
  sign=$(grep -n 'name: Generate, verify and sign SHA256SUMS' "$f" | head -n1 | cut -d: -f1)
  [ -n "$dl" ] && [ -n "$sign" ] && [ "$dl" -lt "$sign" ]
}

publish_needs_offline() { # publish_needs_offline <workflow-file>
  awk '
    /^  publish:/ { inpublish = 1; next }
    inpublish && /^  [a-zA-Z0-9_-]+:/ { exit }
    inpublish && /needs:/ { print; exit }
  ' "$1" | grep -q 'offline-bundle'
}

if order_ok "$RELEASE_WF"; then
  pass "release workflow downloads the offline bundles BEFORE signing SHA256SUMS"
else
  fail "release workflow does not build the offline bundle before signing SHA256SUMS"
fi
if publish_needs_offline "$RELEASE_WF"; then
  pass "the publish job depends on the offline-bundle job"
else
  fail "the publish job does not depend on the offline-bundle job"
fi

# Negative control: move the bundle download step AFTER the signing step in a
# copy of the workflow. The assertion must FAIL there, or it is vacuous.
python3 - "$RELEASE_WF" "$WORK/mutated.yml" <<'PY_INNER'
import sys
src = open(sys.argv[1]).read().split("\n")


def find(needle):
    for i, line in enumerate(src):
        if needle in line:
            return i
    raise SystemExit("negative control: %r not found" % needle)


def end_of_step(start):
    i = start + 1
    while i < len(src) and not src[i].lstrip().startswith("- name:"):
        i += 1
    return i


start = find("name: Download the offline bundles")
end = end_of_step(start)
block = src[start:end]
del src[start:end]
sign = find("name: Generate, verify and sign SHA256SUMS")
src[end_of_step(sign):end_of_step(sign)] = block
open(sys.argv[2], "w").write("\n".join(src))
PY_INNER
if [ $? -ne 0 ]; then
  fail "ordering control: could not derive the mutated workflow (the control is vacuous)"
elif order_ok "$WORK/mutated.yml"; then
  fail "ordering control: the assertion passed on a workflow with the bundle download AFTER signing"
else
  pass "ordering control: the assertion fails when the download is moved after signing"
fi

# ------------------------------------------------------------------ summary
echo "-----------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
