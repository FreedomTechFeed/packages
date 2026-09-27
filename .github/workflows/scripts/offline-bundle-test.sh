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
#   E. the FRESH-BOX dependency CLOSURE: stage (2) of install-router.sh hands apk
#      the dependency files BY PATH, and with --no-network apk resolves a
#      transaction from the files NAMED plus the installed DB only — so a stage
#      that names just the top-level deps REFUSES on a fresh box (nodogsplash's
#      deps are staged but never named, hence `(no such package)`; same bench,
#      wave 3c, release pre19). Upstream PR #178 fixed this AT THE SOURCE, so the
#      builder no longer REWRITES the stage: it GUARDS it. The shipped
#      install-router.sh must be byte-identical to the pin, its stage (2) must
#      offer the WHOLE staged closure to apk, and its gate must report apk's own
#      rc. These checks drive the builder with BOTH installer shapes: the OLD
#      (top-level-deps) shape, which the guard must REFUSE, and the FIXED shape,
#      which it must ACCEPT byte-identically — the FIXED stage (2) is then RUN
#      against an `apk` PATH double that models apk-tools 3 on a WAN-less fresh
#      box, so the assertion is behavioural, not prose. They also include the
#      LANDMINE: the FIXED shape with the builder's marker comment DELETED — a
#      functionally identical file the old rewrite FAILED CLOSED on — must still
#      pass, so a benign upstream reword can never break the build. The as-shipped
#      OLD stage is the control (wave-3 refusal on a fresh box, PASS on an upgrade
#      box, the reason it stayed invisible), and the rc accounting is pinned too
#      (a REFUSED(7) must not report `rc=0`).
#
# Group C is checked against a MUTATED copy of the real workflow as a negative
# control, so the assertion cannot pass vacuously:
#   `order_ok` on the real workflow      -> must PASS
#   `order_ok` on the mutated workflow   -> must FAIL
#
# Run locally:  bash .github/workflows/scripts/offline-bundle-test.sh
# Offline: groups A, B, C, D and E are hermetic (no network, no apk, no router).
#
# ---------------------------------------------------------------------------
# Evidence — both runs executed 2026-09-27 on the offline-bundle worktree, for
# the fresh-box DEPENDENCY-CLOSURE fix (group E). The RED run points the suite at
# a copy of the builder with the dependency-stage repair removed (the pinned
# installer is passed through unchanged), which is the negative control for
# group E; the same mutant is the group-D RED below.
#
# RED   # derive the un-repaired copy: the dependency-stage repair call removed
#       $ python3 - <<'PY'
#       s = open('.github/workflows/scripts/offline-bundle.py').read()
#       s = s.replace('        dep_note = repair_router_dep_stage(bundle_dir)',
#                     '        dep_note = ""  # dependency-stage repair removed')
#       open('/tmp/offline-bundle-nodeprepair.py', 'w').write(s)
#       PY
#       $ OFFLINE_BUNDLE_TEST_SUBJECT=/tmp/offline-bundle-nodeprepair.py \
#             bash .github/workflows/scripts/offline-bundle-test.sh
#   FAIL closure: the bundle's dependency stage still enumerates only REQUIRED_DEPS/STUB_OK_DEPS
#   FAIL closure: an apk invocation still reads `$?` inside `if !` (the rc is the negation's 0)
#   FAIL closure: apk was offered: jq-1.8.1-r2.apk libmicrohttpd-no-ssl-1.0.2-r1.apk
#         libpthread-1.2.5-r5.apk nodogsplash-5.0.2-r2.apk — expected: iptables-mod-conntrack-extra-1.8.10-r3.apk
#         iptables-mod-ipopt-1.8.10-r3.apk iptables-mod-nat-extra-1.8.10-r3.apk iptables-nft-1.8.10-r3.apk
#         jq-1.8.1-r2.apk libmicrohttpd-no-ssl-1.0.2-r1.apk libpthread-1.2.5-r5.apk libxtables-1.8.10-r3.apk
#         nodogsplash-5.0.2-r2.apk xtables-nft-1.8.10-r3.apk
#   FAIL closure: the whole-closure transaction still refuses on a fresh box (rc=7):
#         GATE deps_installed FAIL apk add of the dependency files failed rc=0 REFUSED(7)
#   FAIL closure: the dependency gate misreports the rc (rc=7): GATE deps_installed FAIL
#         apk add of the dependency files failed rc=0
#   FAIL closure: the package gate misreports the rc (rc=7): GATE package_installed FAIL
#         apk add tollgate-wrt_0.6.0_alpha4_pre17_aarch64_cortex-a53.apk failed rc=0
#   FAIL closure: the idempotency input was NOT a repaired installer (the repair never ran)
#   FAIL closure: an unrecognised router-side dependency stage is shipped anyway
#   49 passed, 8 failed        <- rc=1
#
#   (the two CONTROLS in the same run still pass, so the assertion is not
#    vacuous: "the as-shipped stage reproduces the wave-3 refusal (4 of 10 files,
#    REFUSED(7), gate rc=0)" and "the same stage PASSES on an upgrade box")
#
# GREEN $ bash .github/workflows/scripts/offline-bundle-test.sh
#   ok   closure: the bundle's dependency stage offers the staged closure, not just the top-level deps
#   ok   closure: both apk invocations capture apk's own rc (no `rc=0` inside `if !`)
#   ok   closure: the bundle's stage offers every staged package (except the one under test) to apk
#   ok   closure: on a fresh box the whole-closure transaction resolves and deps_installed passes
#   ok   closure control: the as-shipped stage reproduces the wave-3 refusal (4 of 10 files, REFUSED(7), gate rc=0)
#   ok   closure control: the same stage PASSES on an upgrade box — the defect is fresh-box only
#   ok   closure: the dependency gate reports apk's real rc (3), not the negation's 0
#   ok   closure: the package gate reports apk's real rc (3) too
#   ok   closure: the repaired install-router.sh parses under busybox ash
#   ok   closure: reversing the rewrite reproduces the pinned installer byte for byte
#   ok   closure: the rewritten install-router.sh is covered by MANIFEST.sha256
#   ok   closure: re-assembling an already-repaired installer changes nothing
#   ok   closure: an unrecognised dependency stage is refused, naming install-router.sh
#   57 passed, 0 failed        <- rc=0
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

# ------------------------------------------- E: the FRESH-BOX dependency closure
# Hardware observation (bench MT3000, OpenWrt 25.12.5 r33051, WAN-less FRESH
# flash, 2026-09-27 wave 3c, the released pre19 bundle WITH the fresh-box
# keepalive repair applied): the router-side dependency stage REFUSED with exit 7
# before it installed anything, while the bundle carried every package it needed:
#
#   + apk add --no-network --allow-untrusted --force-missing-repositories \
#       <stage>/nodogsplash-5.0.2-r2.apk <stage>/jq-1.8.1-r2.apk \
#       <stage>/libmicrohttpd-no-ssl-1.0.2-r1.apk <stage>/libpthread-1.2.5-r5.apk
#   ERROR: unable to select packages:
#     iptables-mod-conntrack-extra (no such package): required by nodogsplash-5.0.2-r2
#     iptables-mod-ipopt (no such package): required by nodogsplash-5.0.2-r2
#     iptables-mod-nat-extra (no such package): required by nodogsplash-5.0.2-r2
#     iptables-nft (no such package): required by nodogsplash-5.0.2-r2
#   REFUSED(7): the offline dependency install failed.
#   gate deps_installed FAIL apk add of the dependency files failed rc=0
#
# Mechanism (same class as group D): stage (2) hands apk ONLY the files its
# REQUIRED_DEPS + STUB_OK_DEPS loops name — four of the 38 the bundle stages.
# apk-tools 3 resolves a transaction from the files NAMED on the command line
# plus the installed DB and from nothing else, and --no-network leaves no index
# to fall back on, so every dependency that is not named is `(no such package)`
# and apk refuses the whole transaction. `gate bundle_closure PASS required deps
# present:nodogsplash jq libmicrohttpd-no-ssl (38 staged package(s))` says the
# closure was complete; the transaction was not. Only a FRESH flash could see it
# — an upgrade box already has nodogsplash's deps installed, so the same command
# resolves from the DB. That is also why stage (2b)'s runtime gate
# (`iptables --version`, which nodogsplash execs at start-up) had never fired.
#
# This group RUNS the bundle's stage (2) on a simulated fresh box — the `apk`
# PATH double below models apk-tools 3's resolution and the refusal, and records
# its argv — so the assertion is behavioural, not prose: if the stage does not
# offer the WHOLE staged closure, the double refuses and the gate fails, exactly
# as on the bench. The as-shipped (unpatched) fixture is run the same way as a
# control, so a passing assertion cannot be vacuous.
E_SRC="$WORK/depstage-src"
E_APKS="$WORK/depstage-apks"
E_NAMES="nodogsplash-5.0.2-r2 jq-1.8.1-r2 libmicrohttpd-no-ssl-1.0.2-r1 libpthread-1.2.5-r5 iptables-nft-1.8.10-r3 xtables-nft-1.8.10-r3 libxtables-1.8.10-r3 iptables-mod-conntrack-extra-1.8.10-r3 iptables-mod-ipopt-1.8.10-r3 iptables-mod-nat-extra-1.8.10-r3"
mkdir -p "$E_SRC/templates" "$E_APKS"

# The router-side installer as the PINNED commit ships it. The stage (2)/(3) text
# is VERBATIM from OpenTollGate/physical-router-test-automation @9de3726
# scripts/offline/install-router.sh (blob sha256 36fe23c6…, the file the released
# pre19 bundle staged to the bench) — trimmed to those stages.
cat > "$E_SRC/install-router.sh" <<'FIXTURE'
#!/bin/sh
# fixture: the router-side installer of OFFLINE-BUNDLE-2, trimmed to the stages
# this suite runs. Stage (2) and stage (3) below are byte-for-byte the pinned
# text, including the wave-3 dependency-file list and its `$?` accounting.
TGOFFLINE_VERSION="1.0.0"
REQUIRED_DEPS="nodogsplash jq libmicrohttpd-no-ssl"
STUB_OK_DEPS="libpthread"

# =============================================================== 2. deps by path
echo ""
echo "=== (2) dependency packages (BY PATH, --no-network --allow-untrusted --force-missing-repositories) ==="
dep_files=""
for dep in $REQUIRED_DEPS; do
    for f in $STAGED_APKS; do
        case "$(basename "$f")" in
            "$dep-"*) dep_files="$dep_files $f" ;;
        esac
    done
done
for dep in $STUB_OK_DEPS; do
    for f in $STAGED_APKS; do
        case "$(basename "$f")" in
            "$dep-"*) dep_files="$dep_files $f" ;;
        esac
    done
done
# shellcheck disable=SC2086
apk_deps_cmd="apk add --no-network --allow-untrusted --force-missing-repositories$dep_files"
fact apk_deps_cmd "$apk_deps_cmd"
# shellcheck disable=SC2086  # the dependency files must be passed BY PATH, one arg each
echo "+ $apk_deps_cmd"
if ! apk add --no-network --allow-untrusted --force-missing-repositories $dep_files; then
    gate_fail deps_installed "apk add of the dependency files failed rc=$?"
    fail_now 7 "the offline dependency install failed. On a WAN-less router this is usually a missing --force-missing-repositories, a package missing from the bundle's closure, or a package built for another arch."
fi
gate_pass deps_installed "installed:$REQUIRED_DEPS (stubs:$STUB_OK_DEPS)"

# =============================================================== 3. package
echo ""
echo "=== (3) tollgate-wrt package (postinst applies the policy) ==="
if ! apk add --no-network --allow-untrusted --force-missing-repositories "$PKG_APK"; then
    gate_fail package_installed "apk add $APK_NAME failed rc=$?"
    fail_now 7 "installing $APK_NAME failed."
fi
gate_pass package_installed "installed $APK_NAME"
FIXTURE

printf '#!/bin/sh\necho driver\n' > "$E_SRC/install-offline.sh"
write_unsafe_keepalive "$E_SRC/templates/99z-mgmt-keepalive"
chmod +x "$E_SRC/install-offline.sh" "$E_SRC/install-router.sh"
for name in $E_NAMES; do printf 'fixture apk %s\n' "$name" > "$E_APKS/$name.apk"; done
printf 'tollgate package\n' > "$E_APKS/tollgate-wrt_${VERSION}_${ARCH}.apk"

# ---------------------------------------------------------------------------
# The FIXED-shape installer: the same stages as the FIXED upstream pin
# (OpenTollGate/physical-router-test-automation @dc37d1b2 = PR #178 merge, blob
# sha256 596e77cc…), trimmed to the stages this suite runs. Stage (2) below is
# VERBATIM from that file (the whole-closure offer, the apk's-own-rc capture, and
# this builder's marker comment, which upstream copied); stage (3) is its
# apk_pkg_rc block. The guard must ACCEPT this shape and ship it byte-identical.
E_FIX="$WORK/depstage-src-fixed"
mkdir -p "$E_FIX/templates"
cat > "$E_FIX/install-router.sh" <<'FIXTURE'
#!/bin/sh
# fixture: the router-side installer of OFFLINE-BUNDLE-2 as the FIXED upstream
# pin ships it (@dc37d1b2, blob sha256 596e77cc…), trimmed to the stages this
# suite runs. Stage (2) and stage (3) below are byte-for-byte that text,
# including the whole-closure offer and the apk's-own-rc capture.
TGOFFLINE_VERSION="1.0.0"
REQUIRED_DEPS="nodogsplash jq libmicrohttpd-no-ssl"
STUB_OK_DEPS="libpthread"

# =============================================================== 2. deps by path
echo ""
echo "=== (2) dependency packages (BY PATH, --no-network --allow-untrusted --force-missing-repositories) ==="
# --- full-closure offer (added by the offline bundle builder) ----------------
# apk-tools 3 resolves a transaction from the files NAMED here plus the installed
# DB, and from nothing else. With --no-network there is no feed index to fall
# back on, so a dependency of a named package that is NOT itself named is
# `(no such package)` and apk refuses the whole transaction — which is how a
# fresh box got `REFUSED(7): the offline dependency install failed.` while the
# bundle carried every package it needed. Naming only REQUIRED_DEPS+STUB_OK_DEPS
# requires each of THEM to be base-image-complete, and nodogsplash is not
# (iptables-nft, iptables-mod-conntrack-extra, iptables-mod-ipopt,
# iptables-mod-nat-extra). An upgrade box already had those installed, so only a
# fresh flash ever saw it. Offer the WHOLE staged closure in one transaction; the
# package under test is excluded on purpose because stage (3) installs it on its
# own, after the keepalive assertion, so the no-brick ordering is unchanged.
dep_files=""
for f in $STAGED_APKS; do
    if [ "$f" != "$PKG_APK" ]; then
        dep_files="$dep_files $f"
    fi
done
# shellcheck disable=SC2086
apk_deps_cmd="apk add --no-network --allow-untrusted --force-missing-repositories$dep_files"
fact apk_deps_cmd "$apk_deps_cmd"
# shellcheck disable=SC2086  # the dependency files must be passed BY PATH, one arg each
echo "+ $apk_deps_cmd"
# `$?` read inside `if ! cmd; then` is the NEGATION's status (0), so this gate
# once reported a REFUSED(7) as "failed rc=0". Capture apk's own status and
# report that; the verdict and the fail-closed behaviour are unchanged.
apk_deps_rc=0
apk add --no-network --allow-untrusted --force-missing-repositories $dep_files || apk_deps_rc=$?
if [ "$apk_deps_rc" != 0 ]; then
    gate_fail deps_installed "apk add of the dependency files failed rc=$apk_deps_rc"
    fail_now 7 "the offline dependency install failed. On a WAN-less router this is usually a missing --force-missing-repositories, a package missing from the bundle's closure, or a package built for another arch."
fi
gate_pass deps_installed "installed:$REQUIRED_DEPS (stubs:$STUB_OK_DEPS)"

# =============================================================== 3. package
echo ""
echo "=== (3) tollgate-wrt package (postinst applies the policy) ==="
# same `$?`-inside-`if !` accounting as the dependency stage above.
apk_pkg_rc=0
apk add --no-network --allow-untrusted --force-missing-repositories "$PKG_APK" || apk_pkg_rc=$?
if [ "$apk_pkg_rc" != 0 ]; then
    gate_fail package_installed "apk add $APK_NAME failed rc=$apk_pkg_rc"
    fail_now 7 "installing $APK_NAME failed."
fi
gate_pass package_installed "installed $APK_NAME"
FIXTURE

# The LANDMINE: the FIXED fixture minus ONLY the builder's marker comment line — a
# functionally identical file (the same edit on the real pin gives sha 90167441…).
# An earlier builder rewrote stage (2) by matching that exact comment, so deleting
# it alone made the build FAIL CLOSED on a correct installer. The guard must not
# care about any comment.
E_NOMARK="$WORK/depstage-src-nomark"
mkdir -p "$E_NOMARK/templates"
grep -vxF '# --- full-closure offer (added by the offline bundle builder) ----------------' \
  "$E_FIX/install-router.sh" > "$E_NOMARK/install-router.sh"

# A stage that offers the whole closure but still reports apk's status with `$?`
# read from inside `if !` (the negation's 0) — a different shape of the rc defect.
E_RCBAD="$WORK/depstage-src-rcbad"
mkdir -p "$E_RCBAD/templates"
python3 - "$E_FIX/install-router.sh" "$E_RCBAD/install-router.sh" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
good = ('apk_deps_rc=0\n'
        'apk add --no-network --allow-untrusted --force-missing-repositories $dep_files || apk_deps_rc=$?\n'
        'if [ "$apk_deps_rc" != 0 ]; then\n'
        '    gate_fail deps_installed "apk add of the dependency files failed rc=$apk_deps_rc"\n')
bad = ('if ! apk add --no-network --allow-untrusted --force-missing-repositories $dep_files; then\n'
       '    gate_fail deps_installed "apk add of the dependency files failed rc=$?"\n')
assert good in text, "fixture drift: the fixed rc block is not as expected"
open(sys.argv[2], "w", encoding="utf-8").write(text.replace(good, bad))
PY

for d in "$E_FIX" "$E_NOMARK" "$E_RCBAD"; do
  printf '#!/bin/sh\necho driver\n' > "$d/install-offline.sh"
  write_unsafe_keepalive "$d/templates/99z-mgmt-keepalive"
  chmod +x "$d/install-offline.sh" "$d/install-router.sh"
done


python3 - "$E_APKS" "$WORK/depstage-payload.json" "$ARCH" "$VERSION" <<'PY'
import hashlib, json, os, sys
src, out, arch, version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]


def sha(name):
    with open(os.path.join(src, name), "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


members = []
for name in sorted(os.listdir(src)):
    kind = "tollgate-package" if name.startswith("tollgate-wrt_") else "package"
    members.append({"name": name[:-4], "kind": kind, "file": name, "sha256": sha(name),
                    "size": os.path.getsize(os.path.join(src, name)),
                    "path": os.path.join(src, name)})
json.dump({"schema": 1, "release": "25.12.5", "arch": arch,
           "target": "mediatek-filogic", "profile": "glinet_gl-mt3000",
           "members": members, "member_count": len(members),
           "base_provided": [{"name": "libc", "required_by": "jq"}],
           "stubbed": [{"name": "libpthread", "required_by": "nodogsplash"}],
           "closure_closed": True, "apks_dir": src}, open(out, "w"), indent=2)
PY

assemble_e() { # assemble_e <out-dir> [extra args...]
  python3 "$SCRIPT" assemble --payload "$WORK/depstage-payload.json" --arch "$ARCH" \
    --pkg-version "$VERSION" --out "$1" "${@:2}" > "$WORK/assemble-e.log" 2>&1
}

# --- the apk PATH double: apk-tools 3 on a WAN-less box, and nothing else -----
# `add [flags] <file>.apk...` resolves every NAMED package's `depends` against
# the NAMED files + the installed DB + the base image, and refuses the WHOLE
# transaction when one is unresolved — the wave-3 refusal, produced by the same
# mechanism. It records its argv so the test can assert what was offered.
APK_FRESH="$WORK/depstage-bin"; APK_FAIL3="$WORK/depstage-bin-fail3"
mkdir -p "$APK_FRESH" "$APK_FAIL3"
cat > "$APK_FRESH/apk" <<'APK'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${TG_APK_LOG:?}"
depends_of() {
    case "$1" in
        nodogsplash-5.0.2-r2) echo "iptables-nft iptables-mod-conntrack-extra iptables-mod-ipopt iptables-mod-nat-extra libmicrohttpd-no-ssl libpthread" ;;
        iptables-nft-1.8.10-r3) echo "libxtables xtables-nft kernel" ;;
        xtables-nft-1.8.10-r3) echo "libxtables" ;;
        iptables-mod-conntrack-extra-1.8.10-r3) echo "libxtables" ;;
        iptables-mod-ipopt-1.8.10-r3) echo "libxtables" ;;
        iptables-mod-nat-extra-1.8.10-r3) echo "libxtables" ;;
        libxtables-1.8.10-r3) echo "libc" ;;
        jq-1.8.1-r2) echo "libc" ;;
        libmicrohttpd-no-ssl-1.0.2-r1) echo "libc" ;;
        *) echo "" ;;
    esac
}
BASE="libc libgcc kernel"
[ "${1:-}" = "add" ] || exit 0
shift
named=""
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    named="$named $(basename "$a" .apk | sed 's/-[0-9].*$//')"
done
installed=""
[ -f "${TG_APK_DB:-}" ] && installed="$(sed 's/-[0-9].*$//' "$TG_APK_DB" | tr '\n' ' ')"
missing=""
for a in "$@"; do
    case "$a" in -*) continue ;; esac
    name="$(basename "$a" .apk)"
    for d in $(depends_of "$name"); do
        case " $named $installed $BASE " in
            *" $d "*) ;;
            *) missing="$missing $d" ;;
        esac
    done
done
if [ -n "$missing" ]; then
    echo "ERROR: unable to select packages:" >&2
    for m in $missing; do echo "  $m (no such package)" >&2; done
    exit 1
fi
exit 0
APK
chmod +x "$APK_FRESH/apk"
cat > "$APK_FAIL3/apk" <<'APK'
#!/bin/sh
printf '%s\n' "$*" >> "${TG_APK_LOG:?}"
echo "ERROR: (test double) forced apk failure" >&2
exit 3
APK
chmod +x "$APK_FAIL3/apk"

# Extract a stage from a router-side installer so it can be RUN on its own.
extract_stage() { # extract_stage <install-router.sh> <out> <start-regex>
  awk -v s="$3" '$0 ~ s { f=1 } f { print } f && /^gate_pass /{ exit }' "$1" > "$2"
  [ -s "$2" ] && grep -q '^gate_pass ' "$2"
}

run_stage() { # run_stage <stage-file> <out-file> <apk-log> <db-file> <apk-bin-dir> [env...]
  local stage="$1" out="$2" logf="$3" db="$4" bindir="$5"
  local runner="$WORK/depstage-runner.sh"
  {
    printf '#!/bin/sh\n'
    printf 'fact() { :; }\n'
    printf 'gate_pass() { printf "GATE %%s PASS %%s\\n" "$1" "$2"; }\n'
    printf 'gate_fail() { printf "GATE %%s FAIL %%s\\n" "$1" "$2"; }\n'
    printf 'fail_now() { printf "REFUSED(%%s)\\n" "$1"; exit "$1"; }\n'
    printf "STAGED_APKS='%s'\n" "$E_STAGED"
    printf 'PKG_APK="%s"\nAPK_NAME="%s"\n' "$E_PKG_APK" "$(basename "$E_PKG_APK")"
    printf 'REQUIRED_DEPS="nodogsplash jq libmicrohttpd-no-ssl"\nSTUB_OK_DEPS="libpthread"\n'
    printf '. "%s"\n' "$stage"
  } > "$runner"
  : > "$logf"
  TG_APK_LOG="$logf" TG_APK_DB="$db" PATH="$bindir:$PATH" \
    $FB_SH "$runner" > "$out" 2>&1
}

offered_apks() { # offered_apks <apk-log> -> the .apk basenames apk was handed
  tr ' ' '\n' < "$1" | grep -E '\.apk$' | while read -r p; do basename "$p"; done | sort
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# G1: GUARD non-vacuity — the OLD-shape stage (top-level deps only) must be
#     REFUSED. If the guard shipped it anyway, a bundle whose dependency stage
#     refuses on a fresh box would go out. This is the guard's negative control.
if assemble_e "$WORK/out-depstage-old" --installer-dir "$E_SRC"; then
  fail "guard: the OLD-shape dependency stage (top-level deps only) was shipped anyway"
elif grep -qF 'install-router.sh' "$WORK/assemble-e.log" \
     && grep -qF 'REQUIRED_DEPS' "$WORK/assemble-e.log" \
     && grep -qF 'OFFLINE_INSTALLER_REF' "$WORK/assemble-e.log"; then
  pass "guard: the OLD-shape dependency stage is refused, naming install-router.sh, the top-level deps and the re-pin"
else
  fail "guard: the OLD-shape refusal was not actionable: $(tail -n1 "$WORK/assemble-e.log")"
fi

# G2: the guard also pins the rc accounting: a stage that offers the whole closure
#     but reports `$?` from inside `if !` (the negation's 0) is refused.
if assemble_e "$WORK/out-depstage-rcbad" --installer-dir "$E_RCBAD"; then
  fail "guard: a dependency stage that reports the negation's rc (\`\$?\` inside \`if !\`) was shipped anyway"
elif grep -qF "does not capture apk's own status" "$WORK/assemble-e.log"; then
  pass "guard: a dependency stage that does not report apk's own rc is refused"
else
  fail "guard: the rc-accounting refusal was not actionable: $(tail -n1 "$WORK/assemble-e.log")"
fi

# G3: the guard PASSES the FIXED-shape stage and ships it byte-identically.
if assemble_e "$WORK/out-depstage-fixed" --installer-dir "$E_FIX"; then
  E_BUNDLE="$WORK/out-depstage-fixed/tollgate-wrt-${VERSION}-${ARCH}-offline"
  E_IR="$E_BUNDLE/install-router.sh"
  E_STAGED="$(find "$E_BUNDLE/pkgs" -type f -name '*.apk' | sort)"
  E_PKG_APK="$(find "$E_BUNDLE/pkgs" -type f -name 'tollgate-wrt_*.apk' | head -n1)"
  E_EXPECTED="$(printf '%s\n' "$E_STAGED" | grep -v 'tollgate-wrt_' | while read -r p; do basename "$p"; done | sort)"

  pass "guard: the FIXED-shape dependency stage (whole staged closure) is accepted"

  # BYTE-IDENTITY: the shipped installer must equal the pinned source byte for
  # byte — the whole point of replacing the rewrite with a guard.
  if cmp -s "$E_FIX/install-router.sh" "$E_IR"; then
    pass "guard: the shipped install-router.sh is BYTE-IDENTICAL to the pinned source"
  else
    fail "guard: the shipped install-router.sh differs from the pinned source"
  fi

  # E2: BEHAVIOUR, fresh box, GREEN — the shipped stage installs the whole
  #     closure: apk is handed every staged package except the one under test,
  #     the transaction resolves, and the gate passes.
  : > "$WORK/depstage-db-fresh"
  extract_stage "$E_IR" "$WORK/depstage-stage.sh" '^# =+ 2[.] deps by path$' \
    && E_STAGE_OK=1 || E_STAGE_OK=0
  run_stage "$WORK/depstage-stage.sh" "$WORK/depstage-fresh.out" \
            "$WORK/depstage-fresh.apklog" "$WORK/depstage-db-fresh" "$APK_FRESH"
  E_FRESH_RC=$?
  offered="$(offered_apks "$WORK/depstage-fresh.apklog")"
  if [ "$E_STAGE_OK" = 1 ] && [ "$offered" = "$E_EXPECTED" ]; then
    pass "closure: the bundle's stage offers every staged package (except the one under test) to apk"
  else
    fail "closure: apk was offered: $(printf '%s' "$offered" | tr '\n' ' ') — expected: $(printf '%s' "$E_EXPECTED" | tr '\n' ' ')"
  fi
  if [ "$E_FRESH_RC" = 0 ] && grep -q '^GATE deps_installed PASS' "$WORK/depstage-fresh.out"; then
    pass "closure: on a fresh box the whole-closure transaction resolves and deps_installed passes"
  else
    fail "closure: the whole-closure transaction still refuses on a fresh box (rc=$E_FRESH_RC): $(tail -n2 "$WORK/depstage-fresh.out" | tr '\n' ' ')"
  fi

  # E3/E4: CONTROLS — the AS-SHIPPED (old-shape) stage on the same fresh box must
  #     reproduce the wave-3 refusal INCLUDING its rc accounting (else E2 is
  #     vacuous), and must PASS on an upgrade box, which is why the defect
  #     survived the first two waves.
  extract_stage "$E_SRC/install-router.sh" "$WORK/depstage-raw.sh" '^# =+ 2[.] deps by path$' \
    && E_RAW_OK=1 || E_RAW_OK=0
  run_stage "$WORK/depstage-raw.sh" "$WORK/depstage-raw.out" \
            "$WORK/depstage-raw.apklog" "$WORK/depstage-db-fresh" "$APK_FRESH"
  E_RAW_RC=$?
  raw_offered="$(offered_apks "$WORK/depstage-raw.apklog")"
  printf 'nodogsplash-5.0.2-r2.apk\njq-1.8.1-r2.apk\nlibmicrohttpd-no-ssl-1.0.2-r1.apk\nlibpthread-1.2.5-r5.apk\n' > "$WORK/depstage-raw-expected"
  if [ "$E_RAW_RC" = 7 ] && [ "$raw_offered" = "$(sort "$WORK/depstage-raw-expected")" ] \
     && grep -q '^GATE deps_installed FAIL apk add of the dependency files failed rc=0$' "$WORK/depstage-raw.out"; then
    pass "closure control: the as-shipped stage reproduces the wave-3 refusal (4 of 10 files, REFUSED(7), gate rc=0)"
  else
    fail "closure control: the as-shipped stage did NOT reproduce the wave-3 refusal (rc=$E_RAW_RC, offered: $(printf '%s' "$raw_offered" | tr '\n' ' '))"
  fi
  printf 'iptables-nft-1.8.10-r3\niptables-mod-conntrack-extra-1.8.10-r3\niptables-mod-ipopt-1.8.10-r3\niptables-mod-nat-extra-1.8.10-r3\nlibxtables-1.8.10-r3\nxtables-nft-1.8.10-r3\n' > "$WORK/depstage-db-upgrade"
  run_stage "$WORK/depstage-raw.sh" "$WORK/depstage-upgrade.out" \
            "$WORK/depstage-upgrade.apklog" "$WORK/depstage-db-upgrade" "$APK_FRESH"
  E_UP_RC=$?
  if [ "$E_UP_RC" = 0 ] && grep -q '^GATE deps_installed PASS' "$WORK/depstage-upgrade.out"; then
    pass "closure control: the same stage PASSES on an upgrade box — the defect is fresh-box only"
  else
    fail "closure control: the unpatched stage also fails on an upgrade box (rc=$E_UP_RC) — the fixture does not model the bench"
  fi

  # E5/E6: rc ACCOUNTING, GREEN — force apk to fail with 3 and each gate must say 3.
  run_stage "$WORK/depstage-stage.sh" "$WORK/depstage-f5.out" \
            "$WORK/depstage-f5.apklog" "$WORK/depstage-db-fresh" "$APK_FAIL3"
  E_F5_RC=$?
  if [ "$E_F5_RC" = 7 ] && grep -q '^GATE deps_installed FAIL apk add of the dependency files failed rc=3$' "$WORK/depstage-f5.out"; then
    pass "closure: the dependency gate reports apk's real rc (3), not the negation's 0"
  else
    fail "closure: the dependency gate misreports the rc (rc=$E_F5_RC): $(grep '^GATE ' "$WORK/depstage-f5.out" | tr '\n' ' ')"
  fi
  extract_stage "$E_IR" "$WORK/depstage-pkg.sh" '^# =+ 3[.] package$' \
    && E_PKG_OK=1 || E_PKG_OK=0
  run_stage "$WORK/depstage-pkg.sh" "$WORK/depstage-f6.out" \
            "$WORK/depstage-f6.apklog" "$WORK/depstage-db-fresh" "$APK_FAIL3"
  E_F6_RC=$?
  if [ "$E_PKG_OK" = 1 ] && [ "$E_F6_RC" = 7 ] \
     && grep -q "^GATE package_installed FAIL apk add $(basename "$E_PKG_APK") failed rc=3\$" "$WORK/depstage-f6.out"; then
    pass "closure: the package gate reports apk's real rc (3) too"
  else
    fail "closure: the package gate misreports the rc (rc=$E_F6_RC): $(grep '^GATE ' "$WORK/depstage-f6.out" | tr '\n' ' ')"
  fi

  # E7: the shipped installer stays valid shell and is covered by the manifest.
  if $FB_SH -n "$E_IR" >/dev/null 2>&1; then
    pass "closure: the shipped install-router.sh parses under $FB_SH"
  else
    fail "closure: the shipped install-router.sh does not parse under $FB_SH"
  fi
  if (cd "$E_BUNDLE" && sha256sum --check --strict MANIFEST.sha256 >/dev/null 2>&1) \
     && grep -q 'install-router.sh' "$E_BUNDLE/MANIFEST.sha256"; then
    pass "closure: the shipped install-router.sh is covered by MANIFEST.sha256"
  else
    fail "closure: the bundle manifest does not cover the shipped install-router.sh"
  fi

  # E8: idempotent — re-assembling the same (already-guarded) installer changes
  #     nothing (the guard never writes to the file).
  if assemble_e "$WORK/out-depstage-idem" --installer-dir "$E_FIX"; then
    if cmp -s "$E_IR" \
              "$WORK/out-depstage-idem/tollgate-wrt-${VERSION}-${ARCH}-offline/install-router.sh"; then
      pass "closure: re-assembling an already-guarded installer changes nothing"
    else
      fail "closure: re-assembling changed the shipped installer"
    fi
  else
    fail "closure: re-assembling the already-guarded installer failed: $(tail -n2 "$WORK/assemble-e.log")"
  fi
else
  fail "guard: the FIXED-shape dependency stage was REFUSED: $(tail -n2 "$WORK/assemble-e.log")"
fi

# --- G4: the LANDMINE regression that justifies the guard --------------------
# Delete ONLY the builder's marker comment line from the FIXED installer — a
# functionally identical file. An earlier builder rewrote stage (2) by matching
# that exact comment, so deleting it alone made the build FAIL CLOSED on a correct
# installer. The guard must still PASS and still ship it byte-identical.
if assemble_e "$WORK/out-depstage-nomark" --installer-dir "$E_NOMARK"; then
  pass "landmine: the FIXED stage with the builder's marker comment DELETED is still accepted"
  if cmp -s "$E_NOMARK/install-router.sh" \
            "$WORK/out-depstage-nomark/tollgate-wrt-${VERSION}-${ARCH}-offline/install-router.sh"; then
    pass "landmine: the marker-deleted installer is shipped byte-identical"
  else
    fail "landmine: the marker-deleted installer was modified on the way out"
  fi
else
  fail "landmine: deleting the builder's marker comment broke the build: $(tail -n2 "$WORK/assemble-e.log")"
fi

# --- G5: FAIL CLOSED — a real router-side installer with NO stage-(2) region --
mkdir -p "$WORK/depstage-unknown/templates"
cat > "$WORK/depstage-unknown/install-router.sh" <<'UNKNOWN'
#!/bin/sh
TGOFFLINE_VERSION="9.9.9"
REQUIRED_DEPS="nodogsplash jq"
# a future upstream release with a differently shaped dependency stage
apk add --no-network --allow-untrusted --force-missing-repositories "$PKG_DIR"/*.apk
UNKNOWN
chmod +x "$WORK/depstage-unknown/install-router.sh"
cp "$E_SRC/install-offline.sh" "$WORK/depstage-unknown/install-offline.sh"
cp "$E_SRC/templates/99z-mgmt-keepalive" "$WORK/depstage-unknown/templates/99z-mgmt-keepalive"
if assemble_e "$WORK/out-depstage-unknown" --installer-dir "$WORK/depstage-unknown"; then
  fail "closure: an unrecognised router-side dependency stage is shipped anyway"
elif grep -qF 'install-router.sh' "$WORK/assemble-e.log" \
     && grep -qF 'OFFLINE_INSTALLER_REF' "$WORK/assemble-e.log"; then
  pass "closure: an unrecognised dependency stage is refused, naming install-router.sh"
else
  fail "closure: the refusal did not name install-router.sh: $(tail -n1 "$WORK/assemble-e.log")"
fi

# ------------------------------------------------------------------ summary
echo "-----------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
