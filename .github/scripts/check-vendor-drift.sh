#!/bin/sh
# Vendor-drift guard: files the feed vendors from other repos must be
# byte-identical to their upstream source.
#
#   92-tollgate-admin-setup  <- tollgate-captive-portal-site packaging/...
#   rpcd/tollgate_acl.json   <- tollgate-captive-portal-site openwrt/rpcd/...
#
# The feed only substitutes __ADMIN_HOME__ at build time, so the vendored copy
# equals portal main. Drift here is what shipped the pre10 admin regression.
#
# Exit 0 = in sync, 1 = drift (with a diff), 2 = fetch error. Needs network.
set -eu

PORTAL_REPO="${PORTAL_REPO:-OpenTollGate/tollgate-captive-portal-site}"
PORTAL_REF="${PORTAL_REF:-main}"

# "feed path|portal path" (newline separated, no spaces in any path)
PAIRS="
net/tollgate-wrt/files/uci-defaults/92-tollgate-admin-setup|packaging/files/etc/uci-defaults/92-tollgate-admin-setup
net/tollgate-wrt/files/rpcd/tollgate_acl.json|openwrt/rpcd/tollgate_acl.json
"

rc=0
for pair in $PAIRS; do
    feed="${pair%%|*}"
    portal="${pair##*|}"
    url="https://raw.githubusercontent.com/${PORTAL_REPO}/${PORTAL_REF}/${portal}"
    tmp="$(mktemp)"
    if ! curl -fsSL "$url" -o "$tmp"; then
        echo "ERROR: could not fetch $url" >&2
        exit 2
    fi
    if ! diff -u "$tmp" "$feed"; then
        echo "DRIFT: $feed differs from ${PORTAL_REPO}@${PORTAL_REF}:${portal}" >&2
        rc=1
    fi
    rm -f "$tmp"
done

if [ "$rc" != 0 ]; then
    echo "Re-vendor the portal copy over the feed copy, then re-run." >&2
    exit 1
fi
echo "OK: vendored 92 + ACL match ${PORTAL_REPO}@${PORTAL_REF}"
