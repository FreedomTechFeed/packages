#!/bin/sh
# test.sh - verify the tollgate-wrt package installs both binaries AND a usable
# captive portal.
#
# Called by the openwrt/packages buildbot in the test environment after
# installing the tollgate-wrt package. The package is one unit that ships two
# binaries (the service /usr/bin/tollgate-wrt and the CLI /usr/bin/tollgate)
# plus the captive-portal SPA served by uhttpd on :2051.
#
# The portal check matters because the built /assets/*.js|css bundles are
# gitignored upstream and produced at package time by portal-build.sh (Node/npm);
# the SDK feed build cannot run that, so the assets are vendored. A regression
# here ships splash.html that references missing bundles — the browser then
# reports "disallowed MIME type (text/html)" (uhttpd's HTML 404 page) and the
# portal never boots.
#
# Exit status: 0 = pass, 1 = fail.

PORTAL_DIR="/etc/tollgate/tollgate-captive-portal-site"
SPLASH="$PORTAL_DIR/splash.html"

for bin in /usr/bin/tollgate-wrt /usr/bin/tollgate; do
    if [ ! -x "$bin" ]; then
        echo "FAIL: $bin not found" >&2
        exit 1
    fi
    echo "OK: $bin present"
done

# Every /assets/... reference in splash.html must resolve to a real file.
if [ ! -f "$SPLASH" ]; then
    echo "FAIL: $SPLASH not found" >&2
    exit 1
fi

refs=$(grep -oE '/assets/[A-Za-z0-9._-]+' "$SPLASH" | sort -u)
if [ -z "$refs" ]; then
    echo "FAIL: $SPLASH references no /assets bundles (unexpected)" >&2
    exit 1
fi

missing=0
for ref in $refs; do
    if [ -f "$PORTAL_DIR$ref" ]; then
        echo "OK: $ref present"
    else
        echo "FAIL: $SPLASH references missing $ref" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] || exit 1

# Icons referenced by splash.html / manifest.json must be present too.
for asset in logo192.png manifest.json favicon.ico; do
    if [ -f "$PORTAL_DIR/$asset" ]; then
        echo "OK: $asset present"
    else
        echo "FAIL: $PORTAL_DIR/$asset missing" >&2
        exit 1
    fi
done

echo "PASS: both binaries present and captive-portal assets resolve"
exit 0
