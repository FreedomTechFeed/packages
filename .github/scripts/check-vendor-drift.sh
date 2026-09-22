#!/bin/sh
# Vendor-drift guard: files the feed vendors from other repos must be
# byte-identical to their upstream source AT THE PINNED RELEASE COMMIT.
#
#   92-tollgate-admin-setup  <- tollgate-captive-portal-site packaging/...
#   rpcd/tollgate_acl.json   <- tollgate-captive-portal-site openwrt/rpcd/...
#   rpcd/tollgate            <- tollgate-captive-portal-site openwrt/rpcd/...
#
# The reference is net/tollgate-wrt/vendor.lock.json -> portal_commit, i.e. the
# same SHA the bundle build (build-portal-bundle.sh) stages from and the module
# releases against. It is deliberately NOT portal "main": comparing to a moving
# branch turned this guard red on every unrelated portal commit, which is what
# forced ad-hoc re-vendoring and let the shipped 92 diverge from the pin (the
# pre10 admin regression class). A red guard now means "this release's pin is
# not synced", which is actionable, instead of "upstream moved".
#
# Override for the rare ad-hoc check:  PORTAL_REF=<sha-or-branch> sh <this file>
#
# Exit 0 = in sync, 1 = drift (with a diff), 2 = fetch error. Needs network.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
LOCK="$REPO_ROOT/net/tollgate-wrt/vendor.lock.json"

PORTAL_REPO="${PORTAL_REPO:-OpenTollGate/tollgate-captive-portal-site}"
if [ -z "${PORTAL_REF:-}" ]; then
    if [ ! -f "$LOCK" ]; then
        echo "ERROR: vendor.lock.json not found at $LOCK" >&2
        exit 2
    fi
    PORTAL_REF="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["portal_commit"])' "$LOCK")"
fi

# "feed path|portal path" (newline separated, no spaces in any path)
PAIRS="
net/tollgate-wrt/files/uci-defaults/92-tollgate-admin-setup|packaging/files/etc/uci-defaults/92-tollgate-admin-setup
net/tollgate-wrt/files/rpcd/tollgate_acl.json|openwrt/rpcd/tollgate_acl.json
net/tollgate-wrt/files/rpcd/tollgate|openwrt/rpcd/tollgate
"

rc=0
for pair in $PAIRS; do
    feed="$REPO_ROOT/${pair%%|*}"
    portal="${pair##*|}"
    url="https://raw.githubusercontent.com/${PORTAL_REPO}/${PORTAL_REF}/${portal}"
    tmp="$(mktemp)"
    if ! curl -fsSL "$url" -o "$tmp"; then
        echo "ERROR: could not fetch $url" >&2
        rm -f "$tmp"
        exit 2
    fi
    if ! diff -u "$tmp" "$feed"; then
        echo "DRIFT: ${pair%%|*} differs from ${PORTAL_REPO}@${PORTAL_REF}:${portal}" >&2
        rc=1
    fi
    rm -f "$tmp"
done

if [ "$rc" != 0 ]; then
    echo "The feed's pinned release is not in sync. Re-pin + re-vendor from the" >&2
    echo "SAME commit (see docs/architecture/portal-bundle-ownership.md), then re-run." >&2
    exit 1
fi
echo "OK: vendored 92 + rpcd (plugin, ACL) match ${PORTAL_REPO}@${PORTAL_REF}"
