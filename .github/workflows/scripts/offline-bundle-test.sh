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
#   D. the FRESH-BOX keepalive: a freshly flashed box has no
#      /etc/config/nodogsplash, so a seed that resolves @nodogsplash[0] without
#      first creating it lands NOTHING and install-router.sh's keepalive_applied
#      gate then REFUSES with exit 5 (observed on the bench MT3000, 2026-09-27
#      wave 3; an UPGRADE passes). These checks reproduce that on a simulated box
#      (`uci` is a PATH double) and pin the builder to shipping a seed that can
#      establish the trust the installer asserts — while the trust check itself
#      stays strict (a seed without 'allow tcp port 22' must still not pass).
#
# Group C is checked against a MUTATED copy of the real workflow as a negative
# control, so the assertion cannot pass vacuously:
#   `order_ok` on the real workflow      -> must PASS
#   `order_ok` on the mutated workflow   -> must FAIL
#
# Run locally:  bash .github/workflows/scripts/offline-bundle-test.sh
# Offline: groups A, B, C and D are hermetic (no network, no apk, no router).
#
# ---------------------------------------------------------------------------
# Evidence — both runs executed 2026-09-27 on the offline-bundle worktree.
# The RED run points the suite at a copy of the builder with the fresh-box seed
# repair removed (the seed the pinned installer repo ships is passed through
# unchanged), which is the negative control for group D.
#
# RED   # derive the fresh-box-unsafe copy: the repair call removed, nothing else
#       $ python3 - <<'PY'
#       s = open('.github/workflows/scripts/offline-bundle.py').read()
#       s = s.replace('        seed_note = repair_keepalive_seed(bundle_dir)',
#                     '        seed_note = ""  # fresh-box repair removed')
#       open('/tmp/offline-bundle-freshbox-unsafe.py', 'w').write(s)
#       PY
#       $ OFFLINE_BUNDLE_TEST_SUBJECT=/tmp/offline-bundle-freshbox-unsafe.py \
#             bash .github/workflows/scripts/offline-bundle-test.sh
#   FAIL fresh-box: the bundle's seed does not create the anonymous nodogsplash section
#   FAIL fresh-box: the as-shipped seed was shipped unchanged (no repair ran)
#   FAIL fresh-box: the bundle's seed still does not establish live trust on a fresh box
#   FAIL fresh-box: re-applying the seed duplicated the trust entries
#   FAIL fresh-box: a seed that never touches nodogsplash is refused
#   39 passed, 5 failed        <- rc=1
#
# GREEN $ bash .github/workflows/scripts/offline-bundle-test.sh
#   44 passed, 0 failed        <- rc=0
#
# ---------------------------------------------------------------------------
# Evidence — historical: the 2026-09-25 RED run for the ORIGINAL groups A/B/C
# pointed the suite at a copy of the builder with four guards removed (an
# unresolved dependency no longer failed the plan, a bundle could be assembled
# without install-offline.sh, MANIFEST.sha256 stopped covering pkgs/, and a
# member whose bytes changed after fetching was no longer refused):
#
# RED   FAIL missing-dependency fails closed and names it
#       FAIL runtime-dep-absent: a missing RUNTIME dependency is never stubbed
#       FAIL a constrained stale virtual dep is refused (a stub cannot satisfy it)
#       FAIL manifest does not cover the tollgate-wrt package
#       FAIL tampered byte fails the manifest check
#       FAIL a member whose bytes changed after fetching is refused
#       24 passed, 6 failed        <- rc=1
#
# GREEN   30 passed, 0 failed        <- rc=0
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

# The management keepalive seed EXACTLY as it ships from the pinned installer repo
# (OpenTollGate/physical-router-test-automation scripts/offline/templates), with
# the workstation MAC substituted — this is the file that REFUSED a fresh flash.
write_unsafe_keepalive() { # write_unsafe_keepalive <path>
  cat > "$1" <<'SEED'
#!/bin/sh
# 99z — management keepalive (seeded BEFORE anything can start enforcement).
TRUST_MAC="8c:16:45:0d:6f:c5"

TM=$(uci -q get nodogsplash.@nodogsplash[0].trustedmac 2>/dev/null || echo "")
if ! echo "$TM" | grep -q "$TRUST_MAC"; then
    uci add_list nodogsplash.@nodogsplash[0].trustedmac="$TRUST_MAC"
fi

UTR=$(uci -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null || echo "")
if ! echo "$UTR" | grep -q "port 22"; then
    uci add_list nodogsplash.@nodogsplash[0].users_to_router='allow tcp port 22'
fi

uci commit nodogsplash
exit 0
SEED
  chmod +x "$1"
}

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
# The seed as it ships from the pinned installer repo: it resolves the anonymous
# nodogsplash section without first ensuring it exists (group D pins the repair).
write_unsafe_keepalive "$WORK/installer-src/templates/99z-mgmt-keepalive"
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

# ------------------------------------------------- bundles disabled by variable
# OFFLINE-BUNDLE-2 has not landed upstream yet, so a release must still be able to publish
# its package assets. When OFFLINE_INSTALLER_REF is unset the bundle is disabled, and then:
#   * the expected set must be packages-only, or the signed manifest would promise assets
#     that do not exist and the publish guard would reject the release;
#   * the bundle job must still RUN and SUCCEED - a SKIPPED job skips every job that needs
#     it, which would silently withhold the whole release;
#   * publish must still depend on it (asserted above), so the ordering guarantee survives
#     the moment bundles are switched back on.
if grep -q 'EXPECT_ARGS="expected-packages"' "$RELEASE_WF" && grep -q 'release-assets\.py "\$EXPECT_ARGS"' "$RELEASE_WF"; then
  pass "preflight falls back to the package-only expected set when bundles are disabled"
else
  fail "preflight cannot fall back to a package-only expected set (a disabled bundle would break publish)"
fi

if awk '/^  offline-bundle:/ {f=1} f && /id: gate/ {print "gate"; exit}' "$RELEASE_WF" | grep -q gate; then
  pass "the offline-bundle job has a gate step, so a disabled bundle no-ops instead of skipping publish"
else
  fail "the offline-bundle job has no gate step - a disabled bundle would skip publish entirely"
fi

gate_refs=$(grep -c 'steps.gate.outputs.enabled' "$RELEASE_WF" || true)
if [ "${gate_refs:-0}" -ge 4 ]; then
  pass "every bundle step is conditional on the gate ($gate_refs conditional steps)"
else
  fail "only ${gate_refs:-0} bundle step(s) are conditional on the gate - a disabled bundle would still run steps"
fi

# --- the expected-asset output must contain ASSET NAMES ONLY --------------------------------
# A workflow command echoed between "expected<<EXPECTED_ASSETS_EOF" and its EOF becomes part of
# the output VALUE. That is how ":notice::OFFLINE_INSTALLER_REF is not set ..." once entered the
# expected-asset list, making publish refuse with
#   "release is missing expected asset(s): ::notice::..."
EXPECTED_BODY=$(awk '/echo "expected<<EXPECTED_ASSETS_EOF"/{f=1;next} f && /echo "EXPECTED_ASSETS_EOF"/{exit} f' "$RELEASE_WF")
if [ -z "$EXPECTED_BODY" ]; then
  fail "could not locate the expected-assets heredoc in the release workflow"
elif printf '%s\n' "$EXPECTED_BODY" | grep -qE '::(notice|warning|error)::'; then
  fail "a workflow command is echoed inside the expected-assets heredoc - it becomes part of the output value"
else
  pass "no workflow command is echoed inside the expected-assets heredoc"
fi
if printf '%s\n' "$EXPECTED_BODY" | grep -qE 'release-assets\.py "\$EXPECT_ARGS"'; then
  pass "the heredoc emits the chosen expected set in a single call"
else
  fail "the heredoc does not emit the chosen expected set in a single call"
fi

# ------------------------------------------------- D: the FRESH-BOX keepalive
# Hardware observation (bench MT3000, OpenWrt 25.12.5, FRESH flash, 2026-09-27
# wave 3): the released bundle REFUSED with exit 5 BEFORE it installed anything,
# because a freshly flashed box has no /etc/config/nodogsplash. The seed's
#   uci add_list nodogsplash.@nodogsplash[0].trustedmac=...
# cannot resolve an anonymous section that does not exist, so it lands nothing —
# the seed ignores errors and still exits 0 — and install-router.sh's
# keepalive_applied gate then finds no trust and refuses. That is the
# chicken-and-egg: the installer's own pre-install safety gate depends on a
# package the bundle itself delivers. An UPGRADE passed (the config already
# existed), which is why waves 1 and 2 were green and wave 3 was not.
#
# `uci` is a PATH double here that models exactly the one behaviour that matters:
# an anonymous-section path cannot be resolved, and add_list cannot land, until
# the section exists.
FB_SH="sh"
if command -v busybox >/dev/null 2>&1 && busybox ash -c 'true' >/dev/null 2>&1; then
  FB_SH="busybox ash"
elif command -v dash >/dev/null 2>&1; then
  FB_SH="dash"
fi

UCI_DOUBLE="$WORK/uci-double/bin/uci"
mkdir -p "$(dirname "$UCI_DOUBLE")"
cat > "$UCI_DOUBLE" <<'UCI'
#!/bin/sh
# minimal `uci` double. The router is a state directory ($UCI_STATE); the only
# behaviour modelled is real uci's: nodogsplash.@nodogsplash[0] does not resolve,
# and add_list exits non-zero, until the section exists.
S="$UCI_STATE"
[ "$1" = "-q" ] && shift
cmd="$1"; shift 2>/dev/null || true
case "$cmd" in
  get)
    [ -f "$S/section" ] || exit 1
    case "$1" in
      'nodogsplash.@nodogsplash[0]') exit 0 ;;
      *trustedmac) cat "$S/trustedmac" 2>/dev/null; [ -s "$S/trustedmac" ] || exit 1 ;;
      *users_to_router) cat "$S/users_to_router" 2>/dev/null; [ -s "$S/users_to_router" ] || exit 1 ;;
      *) exit 1 ;;
    esac ;;
  add)
    [ "${1:-}" = "nodogsplash" ] || exit 1
    : > "$S/section"; exit 0 ;;
  add_list)
    [ -f "$S/section" ] || exit 1          # real uci: entry not found
    key="$1"; val="${key#*=}"
    case "$key" in
      *trustedmac*) printf '%s\n' "$val" >> "$S/trustedmac" ;;
      *users_to_router*) printf '%s\n' "$val" >> "$S/users_to_router" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
UCI
chmod +x "$UCI_DOUBLE"
PATH="$(dirname "$UCI_DOUBLE"):$PATH"
export PATH

FB_MAC="8c:16:45:0d:6f:c5"
# mirrors install-router.sh assert_keepalive_live(): the trust is "live" only
# when BOTH the MAC is in trustedmac AND 'port 22' is in users_to_router.
fb_trust_live() { # fb_trust_live <state-dir>
  local tm utr
  tm=$(UCI_STATE="$1" "$UCI_DOUBLE" -q get nodogsplash.@nodogsplash[0].trustedmac 2>/dev/null || echo "")
  utr=$(UCI_STATE="$1" "$UCI_DOUBLE" -q get nodogsplash.@nodogsplash[0].users_to_router 2>/dev/null || echo "")
  echo "$tm" | grep -q "$FB_MAC" || return 1
  echo "$utr" | grep -q 'port 22' || return 1
  return 0
}

# D1: the as-shipped seed lands NOTHING on a fresh box. This reproduces the bug
#     through the seed's own logic (and proves the fixture really is the bug —
#     if this passed, D2/D3 would be vacuous).
ST_OLD="$WORK/freshbox-state-old"; mkdir -p "$ST_OLD"
# shellcheck disable=SC2086
UCI_STATE="$ST_OLD" $FB_SH "$WORK/installer-src/templates/99z-mgmt-keepalive" >/dev/null 2>&1
if fb_trust_live "$ST_OLD"; then
  fail "fresh-box: the as-shipped seed established trust (the fixture is not the wave-3 bug)"
else
  pass "fresh-box: the as-shipped seed lands NOTHING with no /etc/config/nodogsplash — the wave-3 refusal"
fi

# D2: the builder repairs the seed, so the BUNDLE's seed creates the section.
mkdir -p "$WORK/freshbox-src/templates"
printf '#!/bin/sh\necho driver\n' > "$WORK/freshbox-src/install-offline.sh"
printf '#!/bin/sh\necho router side\n' > "$WORK/freshbox-src/install-router.sh"
write_unsafe_keepalive "$WORK/freshbox-src/templates/99z-mgmt-keepalive"
cp "$WORK/freshbox-src/templates/99z-mgmt-keepalive" "$WORK/freshbox-seed-input"
chmod +x "$WORK/freshbox-src/install-offline.sh" "$WORK/freshbox-src/install-router.sh"
FB_BUNDLE=""
if assemble "$WORK/out-fresh" --installer-dir "$WORK/freshbox-src"; then
  FB_BUNDLE="$WORK/out-fresh/tollgate-wrt-${VERSION}-${ARCH}-offline"
  FB_SEED="$FB_BUNDLE/templates/99z-mgmt-keepalive"
  if grep -q 'uci add nodogsplash nodogsplash' "$FB_SEED"; then
    pass "fresh-box: the bundle's seed creates the anonymous nodogsplash section when it is absent"
  else
    fail "fresh-box: the bundle's seed does not create the anonymous nodogsplash section"
  fi
  if cmp -s "$WORK/freshbox-seed-input" "$FB_SEED"; then
    fail "fresh-box: the as-shipped seed was shipped unchanged (no repair ran)"
  else
    pass "fresh-box: the builder changed the seed (fresh-box repair applied)"
  fi
  # The repair must not damage the contract install-router.sh asserts on the seed.
  if grep -q 'trustedmac' "$FB_SEED" && grep -q 'port 22' "$FB_SEED" \
     && grep -q "$FB_MAC" "$FB_SEED" && ! grep -q '__TRUST_MAC__' "$FB_SEED"; then
    pass "fresh-box: the repaired seed still carries trustedmac + 'allow tcp port 22' + the MAC"
  else
    fail "fresh-box: the repaired seed lost a fragment install-router.sh asserts"
  fi
  if (cd "$FB_BUNDLE" && sha256sum --check --strict MANIFEST.sha256 >/dev/null 2>&1); then
    pass "fresh-box: the repaired seed is covered by MANIFEST.sha256"
  else
    fail "fresh-box: the repaired seed broke the bundle manifest"
  fi
  # D3: applying the BUNDLE's seed on a fresh box establishes live trust, so
  #     keepalive_applied passes and the install proceeds.
  ST_NEW="$WORK/freshbox-state-new"; mkdir -p "$ST_NEW"
  # shellcheck disable=SC2086
  UCI_STATE="$ST_NEW" $FB_SH "$FB_SEED" >/dev/null 2>&1
  if fb_trust_live "$ST_NEW"; then
    pass "fresh-box: the bundle's seed establishes live trust, so keepalive_applied passes"
  else
    fail "fresh-box: the bundle's seed still does not establish live trust on a fresh box"
  fi
  # D4: idempotent — the seed re-applies at every boot (uci-defaults), so a second
  #     run must not duplicate the entries.
  # shellcheck disable=SC2086
  UCI_STATE="$ST_NEW" $FB_SH "$FB_SEED" >/dev/null 2>&1
  if [ "$(UCI_STATE="$ST_NEW" "$UCI_DOUBLE" -q get nodogsplash.@nodogsplash[0].trustedmac | wc -l)" = "1" ]; then
    pass "fresh-box: re-applying the seed does not duplicate the trust entries"
  else
    fail "fresh-box: re-applying the seed duplicated the trust entries"
  fi
else
  fail "fresh-box: --installer-dir assembly with the as-shipped seed failed: $(tail -n2 "$WORK/assemble.log")"
fi

# D5 (control): the trust check must still FAIL for a fresh-box-safe seed that
#     omits the SSH pre-auth rule — otherwise D3 is vacuous and the fix would
#     have weakened the Aug 16/17 fail-safe.
cat > "$WORK/freshbox-nossh.sh" <<'SEED'
#!/bin/sh
if ! uci -q get nodogsplash.@nodogsplash[0] >/dev/null 2>&1; then
    uci add nodogsplash nodogsplash
fi
uci add_list nodogsplash.@nodogsplash[0].trustedmac="8c:16:45:0d:6f:c5"
uci commit nodogsplash
exit 0
SEED
ST_NS="$WORK/freshbox-state-nossh"; mkdir -p "$ST_NS"
# shellcheck disable=SC2086
UCI_STATE="$ST_NS" $FB_SH "$WORK/freshbox-nossh.sh" >/dev/null 2>&1
if fb_trust_live "$ST_NS"; then
  fail "fresh-box control: the trust check passes with no 'allow tcp port 22' (it is vacuous)"
else
  pass "fresh-box control: the trust check still fails with no SSH pre-auth rule (fail-safe intact)"
fi

# D6: a "seed" that never touches nodogsplash cannot establish the trust the
#     installer asserts, so the builder refuses to ship it, naming the file.
mkdir -p "$WORK/freshbox-bad/templates"
printf '#!/bin/sh\necho not a keepalive\n' > "$WORK/freshbox-bad/templates/99z-mgmt-keepalive"
printf '#!/bin/sh\necho driver\n' > "$WORK/freshbox-bad/install-offline.sh"
if assemble "$WORK/out-fresh-bad" --installer-dir "$WORK/freshbox-bad"; then
  fail "fresh-box: a seed that never touches nodogsplash is refused"
else
  if grep -q '99z-mgmt-keepalive' "$WORK/assemble.log"; then
    pass "fresh-box: a seed that never touches nodogsplash is refused, naming the seed"
  else
    fail "fresh-box: the refusal did not name the seed: $(tail -n1 "$WORK/assemble.log")"
  fi
fi

# ------------------------------------------------------------------ summary
echo "-----------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
