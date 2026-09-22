#!/bin/sh
# test-devendored.sh -- guard the build-in-CI rule (#335) for net/tollgate-wrt.
#
# The feed CONSUMES the captive-portal + admin bundles; it does not own them.
# They are build OUTPUT of OpenTollGate/tollgate-captive-portal-site at the
# commit pinned in net/tollgate-wrt/vendor.lock.json, staged into
# net/tollgate-wrt/files/ by scripts/build-portal-bundle.sh at CI time (a job
# that runs before the gh-action-sdk build, which mounts the workspace as
# /feed and so consumes what was staged).
#
# This test fails when:
#   A. a built bundle file is hand-committed under files/ again (the #335
#      violation this change removes; a stale copy shipped the pre10 admin
#      regression),
#   B. the CI wiring that produces the bundle (and the ngit lane that runs it)
#      disappears, so nothing would rebuild it at package time,
#   C. the pin stops being an immutable full 40-char SHA (a branch/short ref is
#      not reproducible),
#   D. welcome.html stops being installed from the module source tarball -- it
#      is module-owned (byte-identical in feed and module; it exists ONLY in
#      the module) and must not be re-vendored into the feed.
#
# Exit status: 0 = pass, 1 = fail. Run from anywhere; needs git + python3.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FEED="$ROOT/net/tollgate-wrt"
LOCK="$FEED/vendor.lock.json"
BUILD_SH="$FEED/scripts/build-portal-bundle.sh"
FAIL=0

ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

# --- Gate A: no built bundle may be tracked under the generated dirs -------
# files/tollgate-captive-portal-site/ and files/tollgate-admin/ are build
# output (vite builds of the portal repo). Nothing under them belongs in git.
BUILT=$(git -C "$ROOT" ls-files -- \
    "net/tollgate-wrt/files/tollgate-captive-portal-site" \
    "net/tollgate-wrt/files/tollgate-admin" 2>/dev/null)
if [ -n "$BUILT" ]; then
    n=$(printf '%s\n' "$BUILT" | wc -l | tr -d ' ')
    fail "Gate A: $n built bundle file(s) are hand-committed under files/ (must be built in CI, never committed)"
    printf '%s\n' "$BUILT" | sed 's/^/      /' >&2
else
    ok "Gate A: no built bundle files are committed under files/"
fi

# --- Gate B: CI wiring produces the bundle, and the ngit lane runs it ------
if [ -x "$BUILD_SH" ]; then
    ok "Gate B: scripts/build-portal-bundle.sh present and executable"
else
    fail "Gate B: $BUILD_SH missing or not executable"
fi

for wf in \
    ".github/workflows/multi-arch-test-build.yml" \
    ".github/workflows/release-publish.yml" \
    ".ngit/act/workflows/multi-arch-test-build.yml"
do
    if [ ! -f "$ROOT/$wf" ]; then
        fail "Gate B: workflow $wf is missing"
    elif grep -q 'build-portal-bundle.sh' "$ROOT/$wf"; then
        ok "Gate B: $wf builds the bundle in CI"
    else
        fail "Gate B: $wf does not invoke scripts/build-portal-bundle.sh (bundle would never be rebuilt)"
    fi
done

# --- Gate C: the portal pin is an immutable full SHA -----------------------
if [ ! -f "$LOCK" ]; then
    fail "Gate C: $LOCK is missing"
else
    PORTAL_REPO=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("portal_repo",""))' "$LOCK" 2>/dev/null)
    PORTAL_COMMIT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("portal_commit",""))' "$LOCK" 2>/dev/null)
    if [ -z "$PORTAL_REPO" ]; then
        fail "Gate C: vendor.lock.json has no portal_repo"
    else
        ok "Gate C: portal_repo=$PORTAL_REPO"
    fi
    if printf '%s' "$PORTAL_COMMIT" | grep -Eq '^[0-9a-f]{40}$'; then
        ok "Gate C: portal_commit is an immutable 40-char SHA ($PORTAL_COMMIT)"
    else
        fail "Gate C: portal_commit is not a full 40-char SHA (got: '$PORTAL_COMMIT')"
    fi
fi

# --- Gate D: welcome.html is installed from the module source tarball -------
if grep -q 'PKG_TARBALL_DIR)/packaging/files/tollgate-captive-portal-site/welcome.html' "$FEED/Makefile"; then
    ok "Gate D: welcome.html is installed from the module source tarball"
else
    fail "Gate D: Makefile does not install welcome.html from \$(PKG_TARBALL_DIR) (module-owned; must not be vendored)"
fi

# --- Gate E: the existing feed-CI contract still holds ---------------------
if sh "$FEED/test-feed-ci.sh" >/dev/null 2>&1; then
    ok "Gate E: test-feed-ci.sh still passes"
else
    fail "Gate E: test-feed-ci.sh regressed"
fi

if [ "$FAIL" = 1 ]; then
    echo "test-devendored: FAILED" >&2
    exit 1
fi
echo "test-devendored: PASS"
exit 0
