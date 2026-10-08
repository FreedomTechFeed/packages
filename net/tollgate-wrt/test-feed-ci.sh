#!/bin/sh
# test-feed-ci.sh - validate the feed CI publishes per-arch tollgate-wrt
# packages at stable, deterministic URLs.
#
# This is the TDD harness for the "publish per-arch tollgate-wrt" change.
# The feed repo is a Makefile + shell + GitHub Actions repo (no Go), so the
# testable contract is the CI configuration itself:
#
#   1. The build matrix MUST include aarch64_cortex-a53 / mediatek-filogic
#      (the bench GL-MT6000 arch). The openwrt shared workflow's DEFAULT
#      matrix does NOT include it, so the caller MUST pass a custom matrix
#      override or the bench router's arch never builds.
#   2. A release/tag-triggered build MUST exist that uploads per-arch
#      .apk/.ipk assets named deterministically:
#        tollgate-wrt_<PKG_VERSION>_<arch>.apk / .ipk
#      so the wizard can fetch the correct binary for the detected arch.
#   3. (Gate H) The PR build MUST pin a RELEASED OpenWrt branch, never the
#      mutable snapshots/ tree: a snapshot's sha256sums can rotate between the
#      sums fetch and the SDK tarball download, failing the job for reasons
#      unrelated to any PR (measured on PR #46, job aarch64_cortex-a72).
#
# Exit status: 0 = pass, 1 = fail.

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORKFLOW_DIR="$ROOT/.github/workflows"
PKG_DIR="$ROOT/net/tollgate-wrt"
REL_ASSETS="$WORKFLOW_DIR/scripts/release-assets.py"
FAIL=0

fail() {
    echo "FAIL: $1" >&2
    FAIL=1
}

ok() {
    echo "OK: $1"
}

# --- Gate A: build matrix includes aarch64_cortex-a53 / mediatek-filogic ---
# The openwrt shared workflow's default matrix (aarch64_generic/armsr-armv8,
# arm_cortex-a15_neon-vfpv4, ..., x86_64) does NOT include
# aarch64_cortex-a53/mediatek-filogic. The caller must pass a custom matrix
# override. We assert the workflow references the tuple explicitly.
A53_FOUND=0
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -q 'aarch64_cortex-a53' "$f" && grep -q 'mediatek-filogic' "$f"; then
        A53_FOUND=1
        ok "matrix override references aarch64_cortex-a53/mediatek-filogic in $(basename "$f")"
    fi
done
[ "$A53_FOUND" = 1 ] || fail "no workflow references aarch64_cortex-a53/mediatek-filogic (bench GL-MT6000 arch)"

# --- Gate B: release/tag-triggered per-arch asset build exists ---
# A workflow must trigger on tags/releases and upload per-arch assets.
RELEASE_WF=0
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -qE 'on:|release:|tags:' "$f" && grep -q 'upload-release-asset\|gh release upload\|actions/upload-artifact' "$f"; then
        RELEASE_WF=1
        ok "release-triggered asset upload present in $(basename "$f")"
    fi
done
[ "$RELEASE_WF" = 1 ] || fail "no release/tag-triggered workflow uploads per-arch assets"

# --- Gate C: deterministic asset naming ---
# Asset name must be tollgate-wrt_<PKG_VERSION>_<arch>.apk/.ipk. The arch is
# threaded through the matrix; the version comes from the Makefile. We assert
# the naming pattern appears in the release workflow.
PKG_VERSION=$(grep '^PKG_VERSION:=' "$PKG_DIR/Makefile" | sed 's/^PKG_VERSION:=//')
[ -n "$PKG_VERSION" ] || fail "could not read PKG_VERSION from $PKG_DIR/Makefile"
ok "PKG_VERSION=$PKG_VERSION"

NAME_PATTERN_FOUND=0
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -qE 'tollgate-wrt_|tollgate-wrt-.*\.(apk|ipk)' "$f"; then
        NAME_PATTERN_FOUND=1
        ok "deterministic asset naming pattern present in $(basename "$f")"
    fi
done
[ "$NAME_PATTERN_FOUND" = 1 ] || fail "no workflow encodes the tollgate-wrt_<version>_<arch> asset naming pattern"

# --- Gate D: the club device set stays SHIPPABLE ----------------------------
# (2026-10-08, operator product call) The release lane ships exactly the
# arches the club runs: GL-MT3000 and GL-MT6000 (both aarch64_cortex-a53 /
# mediatek-filogic) and the GL.iNet AR300M family (mips_24kc /
# ath79-generic). Every other row is PARKED, not deleted (see Gate K).
#
# This gate asserts the load-bearing half of that call: each club device
# arch must keep BOTH its per-arch .apk release row AND its WAN-less
# offline bundle -- a bundle whose matching package never publishes
# advertises an install path that 404s. The negative control deletes the
# a53 .apk row from a copy and requires the check to refuse it.
club_ship_check() { # club_ship_check <release-assets.py> ; rc 0 = club set shippable
    python3 - "$1" <<'PY'
import json, subprocess, sys
ra = sys.argv[1]
rows = json.loads(subprocess.run([sys.executable, ra, "matrix"],
                                 capture_output=True, text=True, check=True).stdout)["include"]
bundles = json.loads(subprocess.run([sys.executable, ra, "offline-matrix"],
                                    capture_output=True, text=True, check=True).stdout)["include"]
CLUB = [("aarch64_cortex-a53", "mediatek-filogic", "GL-MT3000/GL-MT6000"),
        ("mips_24kc", "ath79-generic", "GL.iNet AR300M")]
rc = 0
for arch, target, device in CLUB:
    if not [r for r in rows if r["arch"] == arch and r["target"] == target and r["ext"] == "apk"]:
        print(f"club arch {arch}/{target} ({device}) has no .apk release row -- cannot install")
        rc = 1
    if not any(b["arch"] == arch and b["target"] == target for b in bundles):
        print(f"club arch {arch}/{target} ({device}) has no WAN-less offline bundle")
        rc = 1
sys.exit(rc)
PY
}
if [ ! -f "$REL_ASSETS" ]; then
    fail "the release matrix script is missing: $REL_ASSETS (Gate D cannot run)"
else
    if _why=$(club_ship_check "$REL_ASSETS"); then
        ok "the club device set (a53 = MT3000/MT6000, mips_24kc = AR300M) keeps its .apk row and offline bundle"
    else
        fail "the club device set is no longer shippable: $_why"
    fi
    _ractl=$(mktemp --suffix=.py)
    sed '/"aarch64_cortex-a53", "mediatek-filogic", "openwrt-25\.12", "apk"/d' "$REL_ASSETS" > "$_ractl"
    if club_ship_check "$_ractl" >/dev/null 2>&1; then
        fail "control: the a53 .apk release row was removed and ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a club device arch whose .apk release row was removed"
    fi
    rm -f "$_ractl"
fi

# --- Gate E: PR CI always builds tollgate-wrt and runtime test is non-blocking ---
# The PR CI is vendored (not the upstream reusable workflow) so that:
#   1. It ALWAYS builds tollgate-wrt. The upstream "Determine changed packages"
#      step only builds packages whose */Makefile changed; a workflow-only PR
#      would fall back to generic test packages and give ZERO signal about
#      tollgate-wrt.
#   2. The runtime smoke test is non-blocking (continue-on-error: true) because
#      upstream bug openwrt/actions-shared-workflows#130 makes it fail
#      deterministically (kmods feed 404) even when the package built fine.
#   3. The runtime-test container BUILD is also non-blocking: the
#      openwrt/rootfs:<arch>-<branch> image does not exist for every arch
#      (aarch64_cortex-a72, arm_cortex-a7, mips64_octeonplus have no rootfs
#      image on Docker Hub), so `docker build` fails with "not found" for those
#      arches even though the package built fine.
# Assert the vendored workflow encodes all three, so a revert to the upstream
# reusable workflow (which reintroduces these problems) is caught.
PR_WF=""
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -q 'name: Test and Build' "$f" && grep -q 'PACKAGES="tollgate-wrt"' "$f"; then
        PR_WF="$f"
    fi
done
if [ -n "$PR_WF" ]; then
    ok "PR CI vendored and always builds tollgate-wrt in $(basename "$PR_WF")"
    # The runtime-test container build step must be non-blocking. Scope the
    # check to the "Build Docker container" step block (from its `- name:` line
    # until the next `- name:` at the same indent) and require a
    # `continue-on-error: true` inside it.
    if awk '
        /^[[:space:]]*- name: Build Docker container/ {inbuild=1; next}
        inbuild && /^[[:space:]]*- name:/ {inbuild=0}
        inbuild && /continue-on-error: true/ {found=1}
        END {exit !found}
    ' "$PR_WF"; then
        ok "runtime-test container build is non-blocking (continue-on-error) in $(basename "$PR_WF")"
    else
        fail "runtime-test container build in $(basename "$PR_WF") is not non-blocking (missing continue-on-error: true on 'Build Docker container')"
    fi
    if grep -q 'continue-on-error: true' "$PR_WF"; then
        ok "runtime smoke test is non-blocking (continue-on-error) in $(basename "$PR_WF")"
    else
        fail "runtime smoke test in $(basename "$PR_WF") is not non-blocking (missing continue-on-error: true)"
    fi
else
    fail "no vendored PR CI workflow always builds tollgate-wrt (PACKAGES=\"tollgate-wrt\")"
fi


# --- Gate H: the PR build pins an IMMUTABLE SDK release, never a snapshot -----
# Measured 2026-10-01 on PR #46 (run 36842992536, job "Test aarch64_cortex-a72"):
# the job fetched targets/bcm27xx/bcm2711/sha256sums at 09:30:57 and the 266 MB
# SDK tarball finished at 09:42:31 -- 12 minutes later. Upstream rotates the
# snapshots/ tree continuously, so the tarball no longer matched the sums that
# had just been downloaded and `sha256sum -c` inside openwrt/gh-action-sdk@v11
# failed with "1 computed checksum did NOT match". That is a property of a
# MUTABLE tree, not of any PR: it can strike any run on any arch and costs a
# full ~30-minute job (7 of 8 arch jobs passed on that run; only the one whose
# SDK rotated mid-download died).
#
# The gate below pins the property that removes the race: the build branch must
# be a RELEASED OpenWrt branch (releases/<version>/targets/<target>/sha256sums
# and the SDK tarball it describes are immutable, so a verify can never race),
# the pin must carry a fail-closed guard against the mutable names, and the
# Build step must not be handed a `-master` snapshot ARCH.
#
# The negative control at the bottom mutates a copy back to `master` and
# requires this check to REFUSE it -- without that, a check that always passes
# would look identical to a check that works.
sdk_pin_check() { # sdk_pin_check <workflow-file> ; rc 0 = pinned immutably
    _f="$1"
    _pin=$(grep -oE 'SDK_BRANCH="[^"]+"' "$_f" 2>/dev/null | head -n1 | sed 's/.*="//;s/"$//')
    case "$_pin" in
        openwrt-[0-9]*.[0-9]*) : ;;
        "") echo "no SDK_BRANCH=\"openwrt-<major>.<minor>\" pin found (a mutable snapshot tree would be built against)"; return 1 ;;
        *)  echo "SDK_BRANCH='$_pin' is not a released openwrt-<major>.<minor> branch"; return 1 ;;
    esac
    if ! grep -qE 'main\|master\|snapshot\*' "$_f"; then
        echo "the pin has no fail-closed guard refusing master/main/snapshot*"
        return 1
    fi
    if grep -qE 'ARCH: \$\{\{ matrix\.arch \}\}-master' "$_f"; then
        echo "the Build step still receives the '-master' snapshot ARCH"
        return 1
    fi
    return 0
}

PR_BUILD_WF="$ROOT/.github/workflows/multi-arch-test-build.yml"
if [ ! -f "$PR_BUILD_WF" ]; then
    fail "the vendored PR build workflow is missing: $PR_BUILD_WF"
else
    if _why=$(sdk_pin_check "$PR_BUILD_WF"); then
        ok "the PR build is pinned to an immutable released SDK branch (no snapshot race)"
    else
        fail "the PR build can hit the SDK snapshot checksum race: $_why"
    fi
    _ctl=$(mktemp)
    sed 's/^\( *SDK_BRANCH=\)"openwrt-[0-9.]*"/\1"master"/' "$PR_BUILD_WF" > "$_ctl"
    if sdk_pin_check "$_ctl" >/dev/null 2>&1; then
        fail "control: a workflow pinned to the mutable 'master' snapshot branch was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a workflow pinned back to the mutable master snapshot branch"
    fi
    rm -f "$_ctl"
fi

# --- Gate I: the RELEASE lane also pins released SDK branches, never snapshots --
# (2026-10-08) Gate H guards the PR workflow, but the tag-triggered release
# matrix (release-assets.py RELEASES) is a SEPARATE table, and its apk lane
# still built against the mutable `master` snapshot while the PR lane was
# pinned. Two measured costs on the pre26 tag (run 37816851786): every apk-lane
# job rebuilt its dependency closure from source because the moved snapshot
# invalidated the gh-action-sdk docker cache scope (openwrt/sdk-<arch>-master),
# and the slowest lane spent 2597 s of a 2630 s job inside the SDK step with
# the tollgate module itself compiling in the final ~60 s. A released branch
# cannot race its sha256sums (Gate H rationale) and its cache scope stays
# valid until the branch moves.
#
# Like Gate F, this parses the table via release-assets.py, not the file text.
# The negative control mutates a copy back to `master` and requires the check
# to refuse it.
release_sdk_pin_check() { # release_sdk_pin_check <release-assets.py> ; rc 0 = all lanes released
    python3 - "$1" <<'PY' >/dev/null 2>&1
import json, re, subprocess, sys
rows = json.loads(subprocess.run(
    ["python3", sys.argv[1], "matrix"], capture_output=True, text=True, check=True).stdout)["include"]
bad = sorted({r["sdk"] for r in rows
              if not re.match(r"^openwrt-[0-9]+\.[0-9]+$", r["sdk"])})
sys.exit(1 if bad else 0)
PY
}
REL_ASSETS="$WORKFLOW_DIR/scripts/release-assets.py"
if [ ! -f "$REL_ASSETS" ]; then
    fail "the release matrix script is missing: $REL_ASSETS"
else
    if release_sdk_pin_check "$REL_ASSETS"; then
        ok "every release-lane SDK is a released openwrt-<major>.<minor> branch (no snapshot lane)"
    else
        fail "a release lane builds against a non-released SDK branch (mutable snapshot: checksum race + permanent cache miss; see Gate H)"
    fi
    _ctl=$(mktemp --suffix=.py)
    sed 's/"openwrt-25\.12", "apk"/"master", "apk"/g' "$REL_ASSETS" > "$_ctl"
    if release_sdk_pin_check "$_ctl" >/dev/null 2>&1; then
        fail "control: a release matrix pinned back to 'master' was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a release matrix pinned back to the mutable master snapshot"
    fi
    rm -f "$_ctl"
fi

# --- Gate J: every release-lane arch keeps an active-or-parked PR row --------
# (2026-10-08) The PR matrix trims compile coverage to the arches on real
# hardware by PARKING rows (commented out, uncomment-to-restore) instead of
# deleting them. Two things must hold:
#   - (this gate) every arch the release lane SHIPS must still appear in the
#     PR workflow as an ACTIVE row or a PARKED comment row, so the restore
#     path is visible where you would restore it. Parking may not become
#     "this arch's restore path silently disappears".
#   - (Gate D) historically-shipped arches cannot leave the release matrix
#     at all. Gate D + this gate together close the "park a row and drop the
#     arch from RELEASES in the same change" hole: D refuses the drop, J
#     refuses the vanished restore path.
# Direction is deliberately one-way: the PR workflow also carries
# aarch64_generic/armsr-armv8, a compile-coverage arch that has NEVER been a
# release-lane row — requiring bidirectional equality would force deleting
# its parked row, which is the opposite of the point.
gate_j() { # gate_j <workflow> <release-assets.py> ; rc 0 = consistent
    _wf="$1"; _ra="$2"
    _rel=$(python3 "$_ra" matrix 2>/dev/null | python3 -c 'import json,sys; print(" ".join(sorted({r["arch"] for r in json.load(sys.stdin)["include"]})))' 2>/dev/null)
    [ -n "$_rel" ] || { echo "cannot parse release matrix"; return 1; }
    _wfarches=$(grep -oE '"arch": "[a-z0-9_-]+"' "$_wf" | sed 's/.*"arch": "//;s/"//' | sort -u | tr '\n' ' ')
    _rc=0
    for _a in $_rel; do
        case " $_wfarches " in *" $_a "*) ;; *)
            echo "release arch '$_a' has no active-or-parked row in the PR workflow (restore path not visible)"; _rc=1 ;; esac
    done
    return $_rc
}

if [ ! -f "$PR_BUILD_WF" ]; then
    fail "the vendored PR build workflow is missing: $PR_BUILD_WF (Gate J cannot run)"
else
    if _why=$(gate_j "$PR_BUILD_WF" "$REL_ASSETS"); then
        ok "every release-lane arch keeps an active-or-parked PR row (parking cannot hide the restore path)"
    else
        fail "PR matrix lost the restore path for a shipped arch: $_why"
    fi
    _wfctl=$(mktemp)
    sed '/"arch": "mips_24kc"/d' "$PR_BUILD_WF" > "$_wfctl"
    if gate_j "$_wfctl" "$REL_ASSETS" >/dev/null 2>&1; then
        fail "control: a shipped arch whose active-or-parked row was deleted from the PR workflow was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a shipped arch with no active-or-parked PR row"
    fi
    rm -f "$_wfctl"
fi

# --- Gate K: parked release rows are still RESTORABLE rows --------------------
# (2026-10-08) The release matrix parks rows the same way the PR matrix does:
# commented out inside the list, exact row text preserved, uncomment to
# restore. "Comment out, don't delete" is only true if the parked text is
# still a well-formed row -- a mangled comment line looks identical to a
# working park until someone tries to restore it. This gate parses every
# commented row line out of release-assets.py and requires it to
# ast.literal_eval into a 4-tuple, i.e. literally paste-back-able. The
# negative control corrupts a parked row's quoting and must be refused.
parked_rows_check() { # parked_rows_check <release-assets.py> ; rc 0 = all parked rows restorable
    python3 - "$1" <<'PY'
import ast, re, sys
src = open(sys.argv[1]).read()
# A parked row: a comment line whose body is a parenthesised literal
# (quoted fields only -- prose comments such as "(arch, target, ...)" are
# skipped because they carry no quotes).
cand = [m.group(1) for m in re.finditer(r'^\s*#\s*(\(.*\))\s*,?\s*$', src, re.M)
        if m.group(1).count('"') >= 4]
if not cand:
    print("no parked release rows found -- parking must keep rows as comments, not delete them")
    sys.exit(1)
rc = 0
for text in cand:
    try:
        t = ast.literal_eval(text)
    except Exception as exc:
        print(f"parked row is not restorable Python: {text}  ({exc})")
        rc = 1
        continue
    if not (isinstance(t, tuple) and len(t) == 4):
        print(f"parked row is not a 4-tuple: {text}")
        rc = 1
sys.exit(rc)
PY
}
if [ ! -f "$REL_ASSETS" ]; then
    fail "the release matrix script is missing: $REL_ASSETS (Gate K cannot run)"
else
    if _why=$(parked_rows_check "$REL_ASSETS"); then
        ok "every parked release row is still a literal, paste-back-able 4-tuple"
    else
        fail "a parked release row cannot be restored: $_why"
    fi
    # Control A: parking degraded into DELETION (no parked rows at all) must be refused.
    _kctl=$(mktemp --suffix=.py)
    sed '/^    # ("/d' "$REL_ASSETS" > "$_kctl"
    if parked_rows_check "$_kctl" >/dev/null 2>&1; then
        fail "control: a matrix whose parked rows were DELETED was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a matrix whose parked rows were deleted"
    fi
    rm -f "$_kctl"
    # Control B: a corrupted parked row (no longer paste-back-able) must be refused.
    _kctl=$(mktemp --suffix=.py)
    sed '/^    # ("x86_64", "x86-64", "openwrt-25\.12", "apk"),$/s/"apk"),/"apk),/' "$REL_ASSETS" > "$_kctl"
    if parked_rows_check "$_kctl" >/dev/null 2>&1; then
        fail "control: a corrupted (unrestorable) parked row was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a corrupted parked row"
    fi
    rm -f "$_kctl"
fi

# --- Gate F: the apk lane that was shipped without a WAN-less bundle ----------
# (2026-10-01) The offline bundle is what lets a FRESH, WAN-less flash install
# tollgate-wrt. The apk lane publishes mips_24kc (ath79-generic) as a real
# per-arch row, so a mips_24kc router with no uplink had NO bundle and could not
# resolve its dependency closure. The gap was invisible from the package matrix
# alone: the apk lane and the bundle lane are SEPARATE tables in
# release-assets.py (RELEASES vs OFFLINE_BUNDLES).
#
# The assertion is scoped to THIS arch on purpose. A bundle is a per-arch
# dependency closure resolved against a pinned OpenWrt release, so "every
# apk-lane arch has a bundle" is the right long-term property but not one this
# change can claim -- the arches still without a bundle are REPORTED below
# rather than asserted, so the test states the gap instead of hiding it.
#
# Both checks parse the tables, not the file text: grepping the Makefile or the
# script for "mips_24kc\" \"ath79-generic\"" also matches the RELEASES table,
# which is how a vacuous version of this gate passed while the bundle row was
# absent.
python3 - "$ROOT/.github/workflows/scripts/release-assets.py" > "$ROOT/.bundle-gate.$$" 2>&1 <<'PY'
import json, subprocess, sys
assets_py = sys.argv[1]
def rows(*argv):
    out = subprocess.run(["python3", assets_py, *argv], capture_output=True,
                         text=True, check=True).stdout
    return json.loads(out)["include"]
apk_arches = sorted({r["arch"] for r in rows("matrix") if r["ext"] == "apk"})
bundles = rows("offline-matrix")
bundle_arches = sorted({r["arch"] for r in bundles})
print("apk-lane arches:    %s" % " ".join(apk_arches))
print("bundle-lane arches: %s" % " ".join(bundle_arches))
mips = [r for r in bundles if r["arch"] == "mips_24kc"]
if not mips:
    print("FAIL mips_24kc has no OFFLINE_BUNDLES row (mips AR300M-class routers cannot install WAN-less)")
    sys.exit(1)
row = mips[0]
if row["target"] != "ath79-generic":
    print("FAIL the mips_24kc bundle row targets %r, not ath79-generic" % row["target"])
    sys.exit(1)
if not row["profile"].startswith("glinet_gl-ar300m"):
    print("FAIL the mips_24kc bundle row names profile %r; expected a glinet_gl-ar300m* device profile "
          "(the profile decides which base-image packages are assumed already present)" % row["profile"])
    sys.exit(1)
if row["ext"] != "apk" or row["release"] != "25.12.5":
    print("FAIL the mips_24kc bundle row is release=%r ext=%r; the apk lane bundles are resolved against "
          "the OpenWrt release the router runs and are apk-tools 3 only" % (row["release"], row["ext"]))
    sys.exit(1)
print("PASS mips_24kc bundle row: target=%s profile=%s release=%s ext=%s"
      % (row["target"], row["profile"], row["release"], row["ext"]))
still_missing = [a for a in apk_arches if a not in bundle_arches]
print("NOTICE apk-lane arches still without a WAN-less bundle (not asserted by this gate): %s"
      % (", ".join(still_missing) or "none"))
PY
BUNDLE_RC=$?
sort -t' ' -k1 .bundle-gate.$$ 2>/dev/null | sed -n 's/^NOTICE /NOTICE: /p'
if [ "$BUNDLE_RC" = 0 ]; then
    ok "$(grep -m1 '^PASS ' .bundle-gate.$$ | sed 's/^PASS //')"
    ok "every apk-lane arch's bundle coverage is accounted for (gaps reported, not hidden)"
else
    fail "$(grep -m1 '^FAIL ' .bundle-gate.$$ | sed 's/^FAIL //')"
fi
rm -f .bundle-gate.$$

# The bundle carries the tollgate-wrt .apk for its arch, so the package matrix
# entry must still exist or the bundle would ship nothing to install.
if python3 "$ROOT/.github/workflows/scripts/release-assets.py" matrix \
     | python3 -c 'import json,sys; d=json.load(sys.stdin)["include"]; sys.exit(0 if any(r["arch"]=="mips_24kc" and r["ext"]=="apk" for r in d) else 1)'; then
    ok "the mips_24kc .apk is still built (the bundle ships it)"
else
    fail "the mips_24kc .apk is no longer in the build matrix (the bundle would ship nothing)"
fi

if [ "$FAIL" = 1 ]; then
    echo "test-feed-ci: FAILED" >&2
    exit 1
fi
echo "test-feed-ci: PASS"
exit 0
