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
#      .apk/.ipk assets named deterministically AND target-qualified:
#        tollgate-wrt_<PKG_VERSION>_<arch>-<target>.apk / .ipk
#      so the wizard can fetch the correct binary for the detected arch AND
#      target -- one arch can serve several targets (mips_24kc is both
#      ath79/generic and ath79/nand), and an arch-only name makes those rows
#      collide on one asset name. The offline bundle carries the target too:
#        tollgate-wrt-<PKG_VERSION>-<arch>-<target>-offline.tar.gz
#      (Gate C: every row's name is target-qualified AND the release workflow
#      derives the name from release-assets.py instead of re-typing it.)
#   3. (Gate L) Every tracked file under the package directory MUST be classified
#      as "travels to upstream" or "fork-local" in UPSTREAM-MANIFEST.txt, so the
#      upstream-mergeable subset stays mechanically extractable.
#   4. (Gate H) The PR build MUST pin a RELEASED OpenWrt branch, never the
#      mutable snapshots/ tree: a snapshot's sha256sums can rotate between the
#      sums fetch and the SDK tarball download, failing the job for reasons
#      unrelated to any PR (measured on PR #46, job aarch64_cortex-a72).
#   5. (Gate M) Every failure message in the package harness (PKG_DIR/test-*.sh)
#      MUST name its gate, so the harness replay wired into feed-gates.yml
#      reports WHICH sub-gate broke instead of an anonymous "the harness failed".
#      Other repo harnesses are out of scope.
#
# Exit status: 0 = pass, 1 = fail.

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORKFLOW_DIR="$ROOT/.github/workflows"
PKG_DIR="$ROOT/net/tollgate-wrt"
REL_ASSETS="$WORKFLOW_DIR/scripts/release-assets.py"
RELEASE_PUBLISH_WF="$WORKFLOW_DIR/release-publish.yml"
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
[ "$A53_FOUND" = 1 ] || fail "Gate A: no workflow references aarch64_cortex-a53/mediatek-filogic (bench GL-MT6000 arch)"

# --- Gate B: release/tag-triggered per-arch asset build exists ---
# A workflow must trigger on tags/releases and upload per-arch assets.
RELEASE_WF=0
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -qE 'on:|release:|tags:' "$f" && grep -q 'upload-release-asset\|gh release upload\|actions/upload-artifact' "$f"; then
        RELEASE_WF=1
        ok "release-triggered asset upload present in $(basename "$f")"
    fi
done
[ "$RELEASE_WF" = 1 ] || fail "Gate B: no release/tag-triggered workflow uploads per-arch assets"

# --- Gate C: deterministic, TARGET-QUALIFIED asset naming ---------------------
# (2026-10-15, Option A) Asset name must be
#   tollgate-wrt_<PKG_VERSION>_<arch>-<target>.apk/.ipk
# and the offline bundle
#   tollgate-wrt-<PKG_VERSION>-<arch>-<target>-offline.tar.gz
#
# The target slot is LOAD-BEARING, not decoration: one CPU arch can serve
# several OpenWrt targets (mips_24kc is both ath79/generic -- AR300M -lite/-16 --
# and ath79/nand -- AR300M -nor/-nand), so an arch-only name makes those two
# rows collide on ONE asset name. That collision is what forced one of them to
# stay parked; with the target in the name both ship at once.
#
# Two structural assertions, because grepping for a literal name is exactly how
# this gate used to pass vacuously:
#   1. every matrix row's TARGET-QUALIFIED name is in the expected asset set,
#      and no row's ARCH-ONLY name is;
#   2. the release workflow DERIVES the staged asset name from
#      release-assets.py (`package-name`), it does not re-type it -- a name that
#      disagrees with the expected set fails the publish job at the far end of a
#      45-minute build, so the two must share one source of truth.
# Controls: an arch-only `package_asset()` (the pre-2026-10-15 shape) and a
# workflow whose derivation was replaced by a hand-typed arch-only name must
# BOTH be refused.
PKG_VERSION=$(grep '^PKG_VERSION:=' "$PKG_DIR/Makefile" | sed 's/^PKG_VERSION:=//')
[ -n "$PKG_VERSION" ] || fail "Gate C: could not read PKG_VERSION from $PKG_DIR/Makefile"
ok "PKG_VERSION=$PKG_VERSION"

QUALIFIED_NAMING_VERSION="9.9.9"

target_qualified_check() { # target_qualified_check <release-assets.py> ; rc 0 = target-qualified
    python3 - "$1" "$QUALIFIED_NAMING_VERSION" <<'PY'
import json, subprocess, sys
ra, version = sys.argv[1], sys.argv[2]


def run(*argv):
    return subprocess.run([sys.executable, ra, *argv],
                          capture_output=True, text=True, check=True).stdout


rows = json.loads(run("matrix"))["include"]
bundles = json.loads(run("offline-matrix"))["include"]
pkgs = run("expected-packages", version).split()
offs = run("expected-offline", version).split()
if not rows:
    print("the release matrix is empty")
    sys.exit(1)
rc = 0
for r in rows:
    want = "tollgate-wrt_%s_%s-%s.%s" % (version, r["arch"], r["target"], r["ext"])
    old = "tollgate-wrt_%s_%s.%s" % (version, r["arch"], r["ext"])
    if want not in pkgs:
        print("matrix row %s/%s does not produce its target-qualified asset %r"
              % (r["arch"], r["target"], want))
        rc = 1
    if old in pkgs:
        print("matrix row %s/%s still produces the ARCH-ONLY asset %r, so two "
              "targets sharing that arch collide" % (r["arch"], r["target"], old))
        rc = 1
for b in bundles:
    want = "tollgate-wrt-%s-%s-%s-offline.tar.gz" % (version, b["arch"], b["target"])
    old = "tollgate-wrt-%s-%s-offline.tar.gz" % (version, b["arch"])
    if want not in offs:
        print("bundle row %s/%s does not produce its target-qualified bundle %r"
              % (b["arch"], b["target"], want))
        rc = 1
    if old in offs:
        print("bundle row %s/%s still produces the ARCH-ONLY bundle %r"
              % (b["arch"], b["target"], old))
        rc = 1
if len(pkgs) != len(rows) or len(offs) != len(bundles):
    print("expected set (%d packages / %d bundles) does not match the matrices "
          "(%d rows / %d rows)" % (len(pkgs), len(offs), len(rows), len(bundles)))
    rc = 1
# The WHOLE POINT of the change: two rows sharing one arch must not share one
# asset name. Pinned on the concrete pair that forced the parking (AR300M
# -lite/-16 ath79-generic vs -nor/-nand ath79-nand, both mips_24kc) so the
# guarantee is asserted by name, not only in aggregate.
if len(set(pkgs)) != len(pkgs):
    dupes = sorted({n for n in pkgs if pkgs.count(n) > 1})
    print("two release rows collide on one asset name: %s" % ", ".join(dupes))
    rc = 1
if len(set(offs)) != len(offs):
    dupes = sorted({n for n in offs if offs.count(n) > 1})
    print("two bundle rows collide on one asset name: %s" % ", ".join(dupes))
    rc = 1
# Pin the guarantee the change exists for, by name: the two AR300M targets
# sharing mips_24kc must resolve to DIFFERENT asset names. Asserted through the
# naming function so it holds even while the ath79-nand row is parked (card t2
# restores it); the arch-only shape makes these two strings equal.
ar_lite = run("package-name", version, "mips_24kc", "ath79-generic", "apk").strip()
ar_nand = run("package-name", version, "mips_24kc", "ath79-nand", "apk").strip()
if not (ar_lite != ar_nand and ar_lite.endswith("-ath79-generic.apk")
        and ar_nand.endswith("-ath79-nand.apk")):
    print("the AR300M targets do not get distinct asset names: ath79/generic -> %r, "
          "ath79/nand -> %r (they share mips_24kc, so the target slot is the only "
          "disambiguator)" % (ar_lite, ar_nand))
    rc = 1
if rc == 0:
    print("every release row's asset name carries its target (%d packages, %d bundles); "
          "AR300M g/n share mips_24kc without colliding" % (len(pkgs), len(offs)))
    print("NOTE (WHAT THIS DOES NOT PROVE): this compares the matrix against the SAME table, "
          "so it cannot detect an expected asset with no matrix row, or a *different* arch-only "
          "shape than the two it greps for. The non-tautological half is the collision/dupe "
          "assertion and the arch-only refusal; see also Gate J (PR matrix) and the "
          "derived_naming_check below (workflow must DERIVE the name).")
sys.exit(rc)
PY
}

# (2) The name must be DERIVED, not re-typed. An arch-only literal in the
# release workflow is the exact shape that has to be impossible.
derived_naming_check() { # derived_naming_check <release workflow> ; rc 0 = derived
    _f="$1"
    grep -q 'release-assets.py package-name' "$_f" \
        || { echo "the staged asset name is not derived from release-assets.py package-name (it is re-typed, so it can drift from the expected set)"; return 1; }
    if grep -qE 'tollgate-wrt_\$\{?PKG_VERSION\}?_?\$?\{?\{? ?matrix\.arch ?\}?\}?\.\$?\{?\{? ?matrix\.ext' "$_f"; then
        echo "the release workflow still hand-types an ARCH-ONLY asset name (no target slot)"; return 1
    fi
    grep -qE 'tollgate-wrt_\*_\$\{\{ matrix\.arch \}\}-\$\{\{ matrix\.target \}\}\.' "$_f" \
        || { echo "the uploaded artifact glob does not require the target slot (tollgate-wrt_*_<arch>-<target>.<ext>)"; return 1; }
    if grep -qE 'tollgate-wrt-%s|tollgate-wrt-\$\{?(args|PKG_VERSION)' "$_f"; then
        echo "the release workflow hand-types an OFFLINE BUNDLE name instead of deriving it from release-assets.py bundle-name"; return 1
    fi
    return 0
}

if [ ! -f "$REL_ASSETS" ]; then
    fail "Gate C: the release matrix script is missing: $REL_ASSETS"
else
    if _why=$(target_qualified_check "$REL_ASSETS"); then
        ok "Gate C: $_why"
    else
        fail "Gate C: asset names are not target-qualified: $_why"
    fi
    # Control A: the pre-2026-10-15 arch-only `package_asset()` must be refused.
    _cctl=$(mktemp --suffix=.py)
    sed 's/return f"tollgate-wrt_{version}_{arch}-{target}.{ext}"/return f"tollgate-wrt_{version}_{arch}.{ext}"/' \
        "$REL_ASSETS" > "$_cctl"
    if target_qualified_check "$_cctl" >/dev/null 2>&1; then
        fail "Gate C: control: an ARCH-ONLY package_asset() was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses an arch-only package_asset() (two targets on one arch would collide)"
    fi
    rm -f "$_cctl"
    # Control B: the arch-only bundle name must be refused.
    _cctl=$(mktemp --suffix=.py)
    sed 's/return f"tollgate-wrt-{version}-{arch}-{target}-offline.tar.gz"/return f"tollgate-wrt-{version}-{arch}-offline.tar.gz"/' \
        "$REL_ASSETS" > "$_cctl"
    if target_qualified_check "$_cctl" >/dev/null 2>&1; then
        fail "Gate C: control: an ARCH-ONLY bundle_asset() was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses an arch-only bundle_asset()"
    fi
    rm -f "$_cctl"
fi

if [ ! -f "$RELEASE_PUBLISH_WF" ]; then
    fail "Gate C: the release publish workflow is missing: $RELEASE_PUBLISH_WF"
else
    if _why=$(derived_naming_check "$RELEASE_PUBLISH_WF"); then
        ok "Gate C: the release workflow derives the target-qualified name from release-assets.py"
    else
        fail "Gate C: the release workflow no longer derives the target-qualified name: $_why"
    fi
    # Control C: re-typing an arch-only name must be refused.
    _cctl=$(mktemp)
    sed 's/release-assets.py package-name/echo tollgate-wrt_static/' "$RELEASE_PUBLISH_WF" > "$_cctl"
    if derived_naming_check "$_cctl" >/dev/null 2>&1; then
        fail "Gate C: control: a re-typed (non-derived) asset name was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a release workflow that re-types the asset name"
    fi
    rm -f "$_cctl"
fi

# --- Gate D: the club device set stays SHIPPABLE ----------------------------
# (2026-10-08, operator product call) The release lane ships exactly the
# arches the club runs: GL-MT3000 and GL-MT6000 (both aarch64_cortex-a53 /
# mediatek-filogic) and the GL.iNet AR300M family (mips_24kc /
# ath79-generic). Every other row is PARKED, not deleted (see Gate K).
#
# This gate asserts the load-bearing half of that call: each club device
# must keep BOTH its per-arch .apk release row AND its WAN-less offline
# bundle -- a bundle whose matching package never publishes advertises an
# install path that 404s.
#
# The contract is the (arch, TARGET) pair, not the arch: since 2026-10-15 the
# target is part of the published asset name, so a club arch repointed to
# another target 404s on install even though its arch row is still present.
# Controls: (A) delete the a53 .apk row; (B) repoint the mips_24kc club row to
# the other target. Both must be REFUSED.
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
    fail "Gate D: the release matrix script is missing: $REL_ASSETS"
else
    if _why=$(club_ship_check "$REL_ASSETS"); then
        ok "the club device set (a53 = MT3000/MT6000, mips_24kc = AR300M) keeps its .apk row and offline bundle"
    else
        fail "Gate D: the club device set is no longer shippable: $_why"
    fi
    _ractl=$(mktemp --suffix=.py)
    sed '/"aarch64_cortex-a53", "mediatek-filogic", "25\.12\.5", "apk"/d' "$REL_ASSETS" > "$_ractl"
    if club_ship_check "$_ractl" >/dev/null 2>&1; then
        fail "Gate D: control: the a53 .apk release row was removed and ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a club device arch whose .apk release row was removed"
    fi
    rm -f "$_ractl"
    # Control B: the club row survives but its TARGET is repointed, so the asset
    # name stops matching what the routers run. Since 2026-10-15 the target is
    # part of the published name, so a repointed target is a 404 on install even
    # though the arch row is still present -- the arch-only check would accept it.
    _ractl=$(mktemp --suffix=.py)
    sed 's/("mips_24kc", "ath79-generic"/("mips_24kc", "ath79-nand"/g' "$REL_ASSETS" > "$_ractl"
    if club_ship_check "$_ractl" >/dev/null 2>&1; then
        fail "Gate D: control: a club arch repointed to another TARGET was ACCEPTED (the arch row alone is not the contract -- the target is in the asset name)"
    else
        ok "control: the check refuses a club arch/target pair repointed to the wrong target"
    fi
    rm -f "$_ractl"
fi

# --- Gate E: PR CI always builds tollgate-wrt; the runtime lane SKIPS a missing
#     rootfs image and keeps its ONE escape hatch scoped + dated ---------------
# The PR CI is vendored (not the upstream reusable workflow) so that:
#   1. It ALWAYS builds tollgate-wrt. The upstream "Determine changed packages"
#      step only builds packages whose */Makefile changed; a workflow-only PR
#      would fall back to generic test packages and give ZERO signal about
#      tollgate-wrt.
#   2. A missing openwrt/rootfs:<arch>-<branch> image SKIPS instead of failing:
#      a preflight step (id: runtime_image) probes the tag, publishes
#      available=true|false via $GITHUB_OUTPUT, and BOTH docker steps are gated
#      on that output. Measured 2026-10-09 (PR #57, run 37999768278): the
#      aarch64_cortex-a53 job died at `FROM openwrt/rootfs:aarch64_cortex-
#      a53-openwrt-25.12` with "not found" (exit 1) and the follow-on "Test via
#      Docker container" died with exit 125 ("Unable to find image
#      'test-container:latest' locally" -- the container was never built), while
#      BOTH steps still carried continue-on-error. A lane whose every red is
#      expected is a lane nobody reads, so a real runtime regression would have
#      been indistinguishable from the known noise.
#   3. The remaining continue-on-error is scoped to the ONE documented upstream
#      bug, openwrt/actions-shared-workflows#130 (the rootfs image carries a
#      kmods feed URL for the kernel it was built with; once the branch moves the
#      old kmods dir 404s and `opkg update` in the container fails), and it sits
#      on the runtime TEST step, never on the container BUILD.
#   4. That escape hatch is DATED: the workflow must carry a REMINDER with an
#      expiry date and the issue link, so it is removed once upstream fixes it.
# Assert all four, so a revert to the upstream reusable workflow (which
# reintroduces these problems) is caught. Three negative controls mutate one
# property each (hatch moved to the container build / gate removed / reminder
# deleted) and must all be REFUSED.
PR_WF=""
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -q 'name: Test and Build' "$f" && grep -q 'PACKAGES="tollgate-wrt"' "$f"; then
        PR_WF="$f"
    fi
done

runtime_lane_check() { # runtime_lane_check <workflow-file> ; rc 0 = de-red contract holds
    _f="$1"
    grep -q 'id: runtime_image' "$_f" \
        || { echo "no rootfs-image availability preflight step (id: runtime_image)"; return 1; }
    grep -q 'echo "available=\$available" >> "\$GITHUB_OUTPUT"' "$_f" \
        || { echo "the preflight does not publish available=... via \$GITHUB_OUTPUT"; return 1; }
    _gated=$(grep -c "steps.runtime_image.outputs.available == 'true'" "$_f")
    [ "$_gated" -ge 2 ] \
        || { echo "only $_gated docker step(s) gated on the preflight result (both must be)"; return 1; }
    # Count real YAML keys only, not the comments that mention the string.
    _coe=$(grep -cE '^[[:space:]]*continue-on-error:[[:space:]]*true' "$_f")
    [ "$_coe" -eq 1 ] \
        || { echo "$_coe continue-on-error escape hatch(es) in the workflow (exactly one is allowed: the #130-scoped runtime test)"; return 1; }
    # Scope each check to its step block: from the `- name:` line until the next
    # `- name:` line.
    if awk '
        /^[[:space:]]*- name: Build Docker container/ {inbuild=1; next}
        inbuild && /^[[:space:]]*- name:/ {inbuild=0}
        inbuild && /^[[:space:]]*continue-on-error: true/ {found=1}
        END {exit !found}
    ' "$_f"; then
        echo "the runtime-test container BUILD is non-blocking again (a missing image is the preflight's business now)"; return 1
    fi
    awk '
        /^[[:space:]]*- name: Test via Docker container/ {intest=1; next}
        intest && /^[[:space:]]*- name:/ {intest=0}
        intest && /^[[:space:]]*continue-on-error: true/ {found=1}
        END {exit !found}
    ' "$_f" \
        || { echo "the runtime TEST lost its escaped hatch for the documented upstream bug (openwrt/actions-shared-workflows#130)"; return 1; }
    grep -q 'actions-shared-workflows#130' "$_f" \
        || { echo "no reference to the upstream bug the escape hatch is scoped to (#130)"; return 1; }
    grep -qE 'REMINDER.*[0-9]{4}-[0-9]{2}-[0-9]{2}' "$_f" \
        || { echo "no DATED reminder to remove the escape hatch once upstream fixes #130"; return 1; }
    return 0
}

if [ -n "$PR_WF" ]; then
    ok "PR CI vendored and always builds tollgate-wrt in $(basename "$PR_WF")"
    if _why=$(runtime_lane_check "$PR_WF"); then
        ok "runtime lane is de-redded: a missing image SKIPs, and the only escape hatch is the dated #130 one on the test step"
    else
        fail "Gate E: the runtime lane can still go permanently RED / hide a real regression: $_why"
    fi
    # Control A: moving the escape hatch onto the container BUILD (the previous
    # shape) must be REFUSED.
    _ectl=$(mktemp)
    awk '/- name: Test via Docker container/ {intest=1}
         !(intest && /^[[:space:]]*continue-on-error: true/)' "$PR_WF" \
      | sed '/- name: Build Docker container/a\        continue-on-error: true' > "$_ectl"
    if runtime_lane_check "$_ectl" >/dev/null 2>&1; then
        fail "Gate E: control: an escape hatch moved onto the container BUILD was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a runtime lane that is non-blocking on the container build"
    fi
    rm -f "$_ectl"
    # Control B: docker steps that are not gated on the preflight must be REFUSED.
    _ectl=$(mktemp)
    sed "s/ && steps.runtime_image.outputs.available == 'true'//g" "$PR_WF" > "$_ectl"
    if runtime_lane_check "$_ectl" >/dev/null 2>&1; then
        fail "Gate E: control: docker steps with no image preflight gate were ACCEPTED (a missing image would go RED again)"
    else
        ok "control: the check refuses docker steps that are not gated on the image preflight"
    fi
    rm -f "$_ectl"
    # Control C: an undated escape hatch (no removable reminder) must be REFUSED.
    _ectl=$(mktemp)
    grep -v 'REMINDER' "$PR_WF" > "$_ectl"
    if runtime_lane_check "$_ectl" >/dev/null 2>&1; then
        fail "Gate E: control: an escape hatch with no dated reminder was ACCEPTED (it could never be removed)"
    else
        ok "control: the check refuses an escape hatch that carries no dated reminder"
    fi
    rm -f "$_ectl"
else
    fail "Gate E: no vendored PR CI workflow always builds tollgate-wrt (PACKAGES=\"tollgate-wrt\")"
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
        [0-9]*.[0-9]*.[0-9]*) : ;;
        openwrt-*) echo "SDK_BRANCH='$_pin' is a BRANCH tag: ghcr branch-tag SDK images are snapshot-built and ship without the SDK, so every job still downloads the ~260 MB tarball (measured 2026-10-08, run 37839847702: 10,434 s on the apk lane). Pin the exact released version, e.g. 25.12.5"; return 1 ;;
        "") echo "no SDK_BRANCH exact-version pin found (a mutable snapshot tree would be built against)"; return 1 ;;
        *)  echo "SDK_BRANCH='$_pin' is not an exact released OpenWrt version (major.minor.patch)"; return 1 ;;
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
    fail "Gate H: the vendored PR build workflow is missing: $PR_BUILD_WF"
else
    if _why=$(sdk_pin_check "$PR_BUILD_WF"); then
        ok "the PR build is pinned to an exact released SDK version (bundled-SDK image: no snapshot race, no per-job tarball download)"
    else
        fail "Gate H: the PR build can hit the SDK snapshot checksum race: $_why"
    fi
    _ctl=$(mktemp)
    sed 's/^\( *SDK_BRANCH=\)"[0-9.]*"/\1"master"/' "$PR_BUILD_WF" > "$_ctl"
    if sdk_pin_check "$_ctl" >/dev/null 2>&1; then
        fail "Gate H: control: a workflow pinned to the mutable 'master' snapshot branch was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a workflow pinned back to the mutable master snapshot branch"
    fi
    rm -f "$_ctl"
    _ctl=$(mktemp)
    sed 's/^\( *SDK_BRANCH=\)"[0-9.]*"/\1"openwrt-25.12"/' "$PR_BUILD_WF" > "$_ctl"
    if sdk_pin_check "$_ctl" >/dev/null 2>&1; then
        fail "Gate H: control: a workflow pinned to the BRANCH tag 'openwrt-25.12' was ACCEPTED (branch-tag images are snapshot-built and SDK-less)"
    else
        ok "control: the check refuses a workflow pinned to the SDK-less branch tag 'openwrt-25.12'"
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
              if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+$", r["sdk"])})
sys.exit(1 if bad else 0)
PY
}
REL_ASSETS="$WORKFLOW_DIR/scripts/release-assets.py"
if [ ! -f "$REL_ASSETS" ]; then
    fail "Gate I: the release matrix script is missing: $REL_ASSETS"
else
    if release_sdk_pin_check "$REL_ASSETS"; then
        ok "every release-lane SDK is an exact released version (bundled-SDK image: no snapshot lane, no per-job tarball download)"
    else
        fail "Gate I: a release lane builds against a non-released SDK branch (mutable snapshot: checksum race + permanent cache miss; see Gate H)"
    fi
    _ctl=$(mktemp --suffix=.py)
    sed 's/"25\.12\.5", "apk"/"master", "apk"/g' "$REL_ASSETS" > "$_ctl"
    if release_sdk_pin_check "$_ctl" >/dev/null 2>&1; then
        fail "Gate I: control: a release matrix pinned back to 'master' was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a release matrix pinned back to the mutable master snapshot"
    fi
    rm -f "$_ctl"
    _ctl=$(mktemp --suffix=.py)
    sed 's/"25\.12\.5", "apk"/"openwrt-25.12", "apk"/g' "$REL_ASSETS" > "$_ctl"
    if release_sdk_pin_check "$_ctl" >/dev/null 2>&1; then
        fail "Gate I: control: a release matrix pinned to the BRANCH tag 'openwrt-25.12' was ACCEPTED (branch-tag images are snapshot-built and SDK-less)"
    else
        ok "control: the check refuses a release matrix pinned to the SDK-less branch tag 'openwrt-25.12'"
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
    # The unit is now the (arch, target) PAIR, not the arch: since 2026-10-15 one
    # arch can carry several release rows (mips_24kc ships ath79-generic AND
    # ath79-nand as real rows), so an arch-only comparison would be satisfied by
    # the WRONG target's row and report a restore path that does not exist.
    _rel=$(python3 "$_ra" matrix 2>/dev/null | python3 -c 'import json,sys; print(" ".join(sorted({r["arch"]+"/"+r["target"] for r in json.load(sys.stdin)["include"]})))' 2>/dev/null)
    [ -n "$_rel" ] || { echo "cannot parse release matrix"; return 1; }
    _wfpairs=$(python3 - "$_wf" <<'PY'
import re, sys
# ACTIVE and PARKED rows alike: an arch/target pair counts as having a restore
# path when it appears in the workflow as a row (or a commented-out row), so
# read the raw text and pair each "arch" with the "target" that follows it.
src = open(sys.argv[1], encoding="utf-8").read()
pairs = set()
for m in re.finditer(r'"arch":\s*"([a-z0-9_-]+)"\s*,\s*"target":\s*"([a-z0-9_-]+)"', src):
    pairs.add("%s/%s" % (m.group(1), m.group(2)))
print(" ".join(sorted(pairs)))
PY
)
    [ -n "$_wfpairs" ] || { echo "the PR workflow declares no arch/target rows"; return 1; }
    _rc=0
    for _p in $_rel; do
        case " $_wfpairs " in *" $_p "*) ;; *)
            echo "release row '$_p' (arch/target) has no active-or-parked row in the PR workflow (restore path not visible)"; _rc=1 ;; esac
    done
    return $_rc
}

if [ ! -f "$PR_BUILD_WF" ]; then
    fail "Gate J: the vendored PR build workflow is missing: $PR_BUILD_WF"
else
    if _why=$(gate_j "$PR_BUILD_WF" "$REL_ASSETS"); then
        ok "every release-lane arch/target keeps an active-or-parked PR row (parking cannot hide the restore path)"
    else
        fail "Gate J: PR matrix lost the restore path for a shipped arch/target: $_why"
    fi
    # Control A: delete the whole arch's rows -> refused.
    _wfctl=$(mktemp)
    sed '/"arch": "mips_24kc"/d' "$PR_BUILD_WF" > "$_wfctl"
    if gate_j "$_wfctl" "$REL_ASSETS" >/dev/null 2>&1; then
        fail "Gate J: control: a shipped arch whose active-or-parked row was deleted from the PR workflow was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a shipped arch with no active-or-parked PR row"
    fi
    rm -f "$_wfctl"
    # Control B: repoint ONE target of a multi-target arch. With the arch-only
    # comparison this passed vacuously (the sibling target's row still named the
    # arch); the (arch, target) unit must catch it. This is the control that
    # makes the upgrade to pairs load-bearing. (The mutation is an edit, not a
    # delete -- review of t1 found this comment claiming a delete.)
    _wfctl=$(mktemp)
    sed 's/"target": "ath79-generic"/"target": "ath79-OTHER"/g' "$PR_BUILD_WF" > "$_wfctl"
    if gate_j "$_wfctl" "$REL_ASSETS" >/dev/null 2>&1; then
        fail "Gate J: control: a shipped (arch, target) pair whose row was repointed to another target was ACCEPTED (an arch-only comparison is vacuous once one arch ships several targets)"
    else
        ok "control: the check refuses a repointed arch/target pair (the pair, not the arch, is the unit)"
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
        continue
    # ...and its TARGET field must be a real value, not blank. Since 2026-10-15
    # the target is part of the published asset name, so restoring a row whose
    # target field was emptied would publish `tollgate-wrt_<ver>_<arch>-.apk`.
    if not all(isinstance(f, str) and f.strip() for f in t):
        print(f"parked row has a blank field (a restored row would publish a "
              f"malformed asset name): {text}")
        rc = 1
sys.exit(rc)
PY
}
if [ ! -f "$REL_ASSETS" ]; then
    fail "Gate K: the release matrix script is missing: $REL_ASSETS"
else
    if _why=$(parked_rows_check "$REL_ASSETS"); then
        ok "every parked release row is still a literal, paste-back-able 4-tuple"
    else
        fail "Gate K: a parked release row cannot be restored: $_why"
    fi
    # Control A: parking degraded into DELETION (no parked rows at all) must be refused.
    _kctl=$(mktemp --suffix=.py)
    sed '/^    # ("/d' "$REL_ASSETS" > "$_kctl"
    if parked_rows_check "$_kctl" >/dev/null 2>&1; then
        fail "Gate K: control: a matrix whose parked rows were DELETED was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a matrix whose parked rows were deleted"
    fi
    rm -f "$_kctl"
    # Control B: a corrupted parked row (no longer paste-back-able) must be refused.
    _kctl=$(mktemp --suffix=.py)
    sed 's/("x86_64", "x86-64", "25\.12\.5", "apk")/("x86_64" "x86-64" "25.12.5" "apk")/' "$REL_ASSETS" > "$_kctl"
    if parked_rows_check "$_kctl" >/dev/null 2>&1; then
        fail "Gate K: control: a corrupted (unrestorable) parked row was ACCEPTED (the check is vacuous)"
    else
        ok "control: the check refuses a corrupted parked row"
    fi
    rm -f "$_kctl"
    # Control C: a parked row whose TARGET field was emptied must be refused.
    # Since 2026-10-15 the target is part of the published asset name, so
    # restoring such a row would publish tollgate-wrt_<ver>_<arch>-.apk.
    _kctl=$(mktemp --suffix=.py)
    sed 's/("mips_24kc", "ath79-nand", "25\.12\.5", "apk")/("mips_24kc", "", "25.12.5", "apk")/' "$REL_ASSETS" > "$_kctl"
    if parked_rows_check "$_kctl" >/dev/null 2>&1; then
        fail "Gate K: control: a parked row with an EMPTY target field was ACCEPTED (restoring it would publish a malformed asset name)"
    else
        ok "control: the check refuses a parked row whose target field is empty"
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
    fail "Gate F: $(grep -m1 '^FAIL ' .bundle-gate.$$ | sed 's/^FAIL //')"
fi
rm -f .bundle-gate.$$

# The bundle carries the tollgate-wrt .apk for its arch AND target, so the
# package matrix entry must still exist or the bundle would ship nothing to
# install. Since 2026-10-15 the lookup is by (arch, target): mips_24kc ships
# both ath79-generic and ath79-nand, so an arch-only lookup would be satisfied
# by the other target's row and the bundle's own package could be absent.
if python3 "$ROOT/.github/workflows/scripts/release-assets.py" matrix \
     | python3 -c 'import json,sys; d=json.load(sys.stdin)["include"]; sys.exit(0 if any(r["arch"]=="mips_24kc" and r["target"]=="ath79-generic" and r["ext"]=="apk" for r in d) else 1)'; then
    ok "the mips_24kc/ath79-generic .apk is still built (the bundle ships it)"
else
    fail "Gate F: the mips_24kc/ath79-generic .apk is no longer in the build matrix (the bundle would ship nothing)"
fi

# --- Gate L: the package ships ONLY bytes upstream can accept ----------------
# Enforced by net/tollgate-wrt/test-upstream-fidelity.sh. That script asserts every
# tracked file under net/tollgate-wrt/ is classified in UPSTREAM-MANIFEST.txt as
# either "travels to openwrt/packages" or "fork-local forever", and that files/ and
# the Makefile always travel. Read its header for why this gate is the thing that
# lets ONE tree serve both a fast container-registry build and an upstream PR
# without a second long-lived branch.
if sh "$PKG_DIR/test-upstream-fidelity.sh"; then
    ok "Gate L: the upstream/fork-local split is explicit and complete"
else
    fail "Gate L: test-upstream-fidelity.sh regressed -- the package no longer has an enforced upstream/fork-local split, so an upstream submission would be undefined"
fi

# --- Gate M: every failure message NAMES its gate ----------------------------
# WHY: feed-gates.yml runs test-devendored.sh, which invokes THIS harness with its
# output redirected to /dev/null and reports only "Gate E: test-feed-ci.sh
# regressed". A second, if:failure() step re-runs the harness to recover the
# detail -- and that replay is only useful if each fail() message says WHICH gate
# broke. Without that, the next sub-gate to regress is anonymous and triage costs
# a full local re-run.
#
# This gate keeps the naming honest as sub-gates are ADDED. It is the cheapest
# possible check (a grep) and it goes red the moment someone writes a bare
# fail(), so "which gate failed?" cannot quietly rot into "Gate E failed".
# NOTE: grep is line-granular, so an unnamed fail() sharing a physical line with a
# named one would be excluded with that line. No such line exists today.
_gm_files=0
_gm_named=0
_gm_bad=0
for _hm in "$PKG_DIR"/test-*.sh; do
    [ -f "$_hm" ] || continue
    _gm_files=$((_gm_files + 1))
    _gm_named=$((_gm_named + $(grep -cE 'fail[[:space:]]+"Gate [A-Za-z0-9]+[.:]' "$_hm" 2>/dev/null || true)))
    _unnamed=$(grep -nE 'fail[[:space:]]+"' "$_hm" 2>/dev/null | grep -vE 'fail[[:space:]]+"Gate [A-Za-z0-9]+[.:]' || true)
    if [ -n "$_unnamed" ]; then
        _gm_bad=$((_gm_bad + 1))
        _n=$(printf '%s\n' "$_unnamed" | wc -l)
        fail "Gate M: $(basename "$_hm") has $_n failure message(s) that do not name their gate, so a regression reports only 'the harness failed'. First: $(printf '%s\n' "$_unnamed" | head -1 | cut -d: -f2- | sed 's/^[[:space:]]*//' | cut -c1-100)"
    fi
done
[ "$_gm_bad" = 0 ] && ok "Gate M: every failure message in the package harness names its gate ($_gm_named named across $_gm_files files)"

if [ "$FAIL" = 1 ]; then
    echo "test-feed-ci: FAILED" >&2
    exit 1
fi
echo "test-feed-ci: PASS"
exit 0
