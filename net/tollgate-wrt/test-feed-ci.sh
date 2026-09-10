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
#
# Exit status: 0 = pass, 1 = fail.

set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORKFLOW_DIR="$ROOT/.github/workflows"
PKG_DIR="$ROOT/net/tollgate-wrt"
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

# --- Gate D: existing arches preserved ---
# The change must NOT drop the existing mipsel_24kc / mips_24kc / x86_64
# builds. Assert the matrix override (or default) still covers them.
for arch in mipsel_24kc mips_24kc x86_64; do
    FOUND=0
    for f in "$WORKFLOW_DIR"/*.yml; do
        if grep -q "$arch" "$f"; then
            FOUND=1
            ok "existing arch $arch preserved in $(basename "$f")"
        fi
    done
    [ "$FOUND" = 1 ] || fail "existing arch $arch missing from all workflows"
done

# --- Gate E: PR CI always builds tollgate-wrt and runtime test is non-blocking ---
# The PR CI is vendored (not the upstream reusable workflow) so that:
#   1. It ALWAYS builds tollgate-wrt. The upstream "Determine changed packages"
#      step only builds packages whose */Makefile changed; a workflow-only PR
#      would fall back to generic test packages and give ZERO signal about
#      tollgate-wrt.
#   2. The runtime smoke test is non-blocking (continue-on-error: true) because
#      upstream bug openwrt/actions-shared-workflows#130 makes it fail
#      deterministically (kmods feed 404) even when the package built fine.
# Assert the vendored workflow encodes both, so a revert to the upstream
# reusable workflow (which reintroduces both problems) is caught.
PR_WF=""
for f in "$WORKFLOW_DIR"/*.yml; do
    if grep -q 'name: Test and Build' "$f" && grep -q 'PACKAGES="tollgate-wrt"' "$f"; then
        PR_WF="$f"
    fi
done
if [ -n "$PR_WF" ]; then
    ok "PR CI vendored and always builds tollgate-wrt in $(basename "$PR_WF")"
    if grep -q 'continue-on-error: true' "$PR_WF"; then
        ok "runtime smoke test is non-blocking (continue-on-error) in $(basename "$PR_WF")"
    else
        fail "runtime smoke test in $(basename "$PR_WF") is not non-blocking (missing continue-on-error: true)"
    fi
else
    fail "no vendored PR CI workflow always builds tollgate-wrt (PACKAGES=\"tollgate-wrt\")"
fi

if [ "$FAIL" = 1 ]; then
    echo "test-feed-ci: FAILED" >&2
    exit 1
fi
echo "test-feed-ci: PASS"
exit 0
