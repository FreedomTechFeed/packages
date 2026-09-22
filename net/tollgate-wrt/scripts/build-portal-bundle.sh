#!/bin/sh
# build-portal-bundle.sh -- build the captive-portal + admin SPAs from the pinned
# portal commit and stage them for the tollgate-wrt package build.
#
# WHY THIS EXISTS (#335: build in CI with an artifact, never commit built assets)
#
# The guest portal SPA and the admin board are BUILD OUTPUT of
# OpenTollGate/tollgate-captive-portal-site: `npm run build`
# (scripts/build-all.mjs) emits build/ (guest portal + balance) and
# build/admin/ (Preact admin board). A hand-committed copy of either is the
# exact #335 violation this card removes — and it is how the pre10 admin
# regression shipped (a stale vendored copy). This feed must never carry a
# committed built bundle again.
#
# This script:
#   1. clones the portal repo at the IMMUTABLE commit pinned in
#      net/tollgate-wrt/vendor.lock.json (the single source of truth for what
#      the package ships),
#   2. runs `npm ci && npm run build`,
#   3. stages build/*  (minus build/admin/)  -> files/tollgate-captive-portal-site/
#      and  build/admin/*                    -> files/tollgate-admin/,
#   4. VERIFIES the staged bytes against vendor.lock.json (so nothing ships
#      unless the lock is truthful), and
#   5. fails loudly on any divergence.
#
# The gh-action-sdk build (multi-arch-test-build.yml / release-publish.yml)
# mounts the workspace as /feed, so it consumes exactly what was staged here.
# No SDK step reaches a second repository, and no built asset is committed.
#
# welcome.html is deliberately NOT produced here: the portal build never emits
# it; it is MODULE-owned and installed from the module source tarball by the
# Makefile (see docs/architecture/portal-bundle-ownership.md).
#
# Usage: build-portal-bundle.sh           # clone+build+stage+verify
# Exit 0 on success, non-zero on any failure.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FEED_DIR=$(CDPATH= cd -- "$HERE/.." && pwd)          # net/tollgate-wrt
REPO_DIR=$(CDPATH= cd -- "$FEED_DIR/../.." && pwd)       # repo root
LOCK="$FEED_DIR/vendor.lock.json"
PORTAL_DIR="$FEED_DIR/files/tollgate-captive-portal-site"
ADMIN_DIR="$FEED_DIR/files/tollgate-admin"

die() { echo "build-portal-bundle: ERROR: $*" >&2; exit 1; }
sha()  { sha256sum "$1" | awk '{print $1}'; }

[ -f "$LOCK" ] || die "vendor.lock.json not found at $LOCK"
command -v git >/dev/null || die "git required"
command -v python3 >/dev/null || die "python3 required"
command -v npm >/dev/null || die "npm required"

# --- resolve the pin from vendor.lock.json ---
PIN_REPO=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["portal_repo"])' "$LOCK")
PIN_COMMIT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["portal_commit"])' "$LOCK")
case "$PIN_COMMIT" in
  *[!0-9a-f]*|'') die "portal_commit is not hex: '$PIN_COMMIT'" ;;
esac
[ "$(printf '%s' "$PIN_COMMIT" | wc -c)" = 40 ] || die "portal_commit is not a 40-char SHA: '$PIN_COMMIT' (floating/tag refs are not reproducible)"
echo "build-portal-bundle: pin $PIN_REPO@$PIN_COMMIT"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/portal-bundle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- rebuild the portal at the pin ---
git clone --quiet --no-checkout "https://github.com/$PIN_REPO" "$WORK/portal"
git -C "$WORK/portal" checkout --quiet "$PIN_COMMIT"
GOT=$(git -C "$WORK/portal" rev-parse HEAD)
[ "$GOT" = "$PIN_COMMIT" ] || die "checkout mismatch: wanted $PIN_COMMIT got $GOT"

( cd "$WORK/portal" && npm ci --no-audit --no-fund ) || die "npm ci failed"
( cd "$WORK/portal" && npm run build ) || die "npm run build failed"
[ -d "$WORK/portal/build" ] || die "no build/ after npm run build"
[ -d "$WORK/portal/build/admin" ] || die "no build/admin/ after npm run build"

# --- stage into files/ (replace any stale output) ---
rm -rf "$PORTAL_DIR" "$ADMIN_DIR"
mkdir -p "$PORTAL_DIR" "$ADMIN_DIR"
# guest portal + balance: everything in build/ except the admin board
for entry in "$WORK/portal/build"/*; do
    [ "$(basename "$entry")" = "admin" ] && continue
    cp -R "$entry" "$PORTAL_DIR/"
done
# admin board: installed at the ROOT of the :8090 uhttpd webroot
for entry in "$WORK/portal/build/admin"/*; do
    cp -R "$entry" "$ADMIN_DIR/"
done
# welcome.html is module-only; never stage it (the Makefile installs it from the
# module tarball).

PORTAL_N=$(find "$PORTAL_DIR" -type f | wc -l | tr -d ' ')
ADMIN_N=$(find "$ADMIN_DIR" -type f | wc -l | tr -d ' ')
echo "build-portal-bundle: staged $PORTAL_N guest-portal + $ADMIN_N admin file(s)"

# --- verify staged bytes against vendor.lock.json ---
# The lock's "files" map is the authoritative manifest of what the pin produces
# (guest-portal site minus welcome.html, plus admin, plus rpcd ACL). Recompute
# and diff. Any mismatch = the pin no longer produces the locked bundle.
if python3 - <<'PY' "$LOCK" "$PORTAL_DIR" "$ADMIN_DIR" "$REPO_DIR"
import hashlib, json, os, sys
lock_f, portal_dir, admin_dir, repo_dir = sys.argv[1:5]
lock = json.load(open(lock_f))
want = lock.get("files", {})
have = {}
for d in (portal_dir, admin_dir):
    for root, _dirs, names in os.walk(d):
        for n in names:
            p = os.path.join(root, n)
            rel = os.path.relpath(os.path.realpath(p), os.path.realpath(repo_dir))
            have[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
bad = 0
for rel in want:
    if rel not in have:
        # rpcd ACL is tracked source, not a build output; skip it here.
        if "files/rpcd/tollgate_acl.json" in rel:
            continue
        print("DRIFT: %s is in the lock but not produced by the build" % rel, file=sys.stderr)
        bad = 1
    elif have[rel] != want[rel]:
        print("DRIFT: %s sha256 differs from the lock" % rel, file=sys.stderr)
        bad = 1
for rel in have:
    if rel not in want:
        print("DRIFT: %s produced by the build but not in the lock (re-lock)" % rel, file=sys.stderr)
        bad = 1
sys.exit(1 if bad else 0)
PY
then
    echo "build-portal-bundle: verified staged file(s) against vendor.lock.json"
else
    die "staged bundle does not match vendor.lock.json ($PIN_REPO@$PIN_COMMIT) — re-lock before shipping"
fi

echo "build-portal-bundle: OK ($PIN_REPO@$PIN_COMMIT)"
exit 0
