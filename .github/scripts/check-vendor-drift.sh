#!/bin/sh
# Vendor-drift guard: the feed's admin setup script must be byte-identical to
# portal-site main.
#
# 92-tollgate-admin-setup is OWNED by OpenTollGate/tollgate-captive-portal-site
# (packaging/files/etc/uci-defaults/). The feed vendors an exact copy and lets
# the Makefile substitute __ADMIN_HOME__ at build time, so the vendored file
# must equal portal main exactly. Drift is what shipped the pre10 admin
# regression: the vendored copy predated the __ADMIN_HOME__ refactor, so the
# Makefile's $(SED) matched nothing and the brand webroot was never set.
#
# Exit 0 = in sync, 1 = drift (with a diff), 2 = fetch error. Needs network.
set -eu

PORTAL_REPO="${PORTAL_REPO:-OpenTollGate/tollgate-captive-portal-site}"
PORTAL_REF="${PORTAL_REF:-main}"
PORTAL_PATH="packaging/files/etc/uci-defaults/92-tollgate-admin-setup"
VENDORED="net/tollgate-wrt/files/uci-defaults/92-tollgate-admin-setup"

url="https://raw.githubusercontent.com/${PORTAL_REPO}/${PORTAL_REF}/${PORTAL_PATH}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL "$url" -o "$tmp"; then
    echo "ERROR: could not fetch $url" >&2
    exit 2
fi

if ! diff -u "$tmp" "$VENDORED"; then
    echo >&2
    echo "DRIFT: $VENDORED differs from ${PORTAL_REPO}@${PORTAL_REF}:${PORTAL_PATH}" >&2
    echo "Re-vendor the portal copy over the feed copy, then re-run." >&2
    exit 1
fi

echo "OK: vendored 92 matches ${PORTAL_REPO}@${PORTAL_REF}"
