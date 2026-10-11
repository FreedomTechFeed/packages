#!/bin/sh
# tollgate-release-url.sh -- resolve the tollgate-wrt download URL for a release.
#
# The release TAG and the package asset name are NOT the same string:
#
#     tag   : v0.6.0-rc1-pre29                        (leading 'v', hyphens)
#     asset : tollgate-wrt_0.6.0_rc1_pre29_aarch64_cortex-a53.apk
#                                                     (no 'v', underscores)
#
# Two field failures are why this script exists:
#
#   1. A handoff snippet resolved the tag with `gh`, which OpenWrt does not
#      ship, so the version came out EMPTY and produced
#        .../releases/download//tollgate-wrt__aarch64_cortex-a53.apk
#      (the double slash is the tell: nothing where the tag belongs).
#   2. Even with a tag in hand, copying it into the version slot can never
#      work -- the two strings differ, per the table above.
#
# This script needs a POSIX shell and nothing else. It never prints a URL it
# cannot construct: empty or malformed input is a hard error, not a warning.
#
# Usage:
#   tollgate-release-url.sh <tag-or-version> <arch> [apk|ipk]
#   tollgate-release-url.sh --check <tag-or-version> <arch> [apk|ipk]
#   tollgate-release-url.sh --arches
#
# Examples:
#   tollgate-release-url.sh v0.6.0-rc1-pre29 aarch64_cortex-a53
#   tollgate-release-url.sh 0.6.0_rc1_pre29 mips_24kc ipk
#   tollgate-release-url.sh --check v0.6.0-rc1-pre29 aarch64_cortex-a53
#
# `--check` downloads the asset, requires it to be listed in the release's
# signed SHA256SUMS, and compares digests. It exits non-zero on any mismatch,
# so it is safe to use as a self-gating step in a handoff.
#
# Exit codes: 0 ok | 2 usage | 3 empty/malformed input | 4 --check failed.

set -u

REPO="${TOLLGATE_RELEASE_REPO:-FreedomTechFeed/packages}"
PREFIX="tollgate-wrt"

# Club arches (docs/per-arch-release-assets.md). Old releases also carry parked
# arches; we accept any arch tuple, but we do not silently invent one.
CLUB_ARCHES="aarch64_cortex-a53 mips_24kc"

die() { printf 'tollgate-release-url: %s\n' "$1" >&2; exit "${2:-3}"; }

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") <tag-or-version> <arch> [apk|ipk]
       $(basename "$0") --check <tag-or-version> <arch> [apk|ipk]
       $(basename "$0") --arches

  <tag-or-version>  v0.6.0-rc1-pre29  or  0.6.0_rc1_pre29  (both accepted)
  <arch>            e.g. aarch64_cortex-a53, mips_24kc
  [apk|ipk]         apk (OpenWrt 25.12, default) or ipk (24.10)

club arches: $CLUB_ARCHES
EOF
    exit 2
}

have() { command -v "$1" >/dev/null 2>&1; }

# tag -> version : v0.6.0-rc1-pre29   -> 0.6.0_rc1_pre29
to_version() { printf '%s' "$1" | sed 's/^v//' | tr '-' '_'; }
# version -> tag : 0.6.0_rc1_pre29    -> v0.6.0-rc1-pre29
to_tag()     { printf 'v%s' "$(printf '%s' "$1" | tr '_' '-')"; }

fetch() { # fetch <url> <dest>; 0 on success
    if have curl; then
        curl -fsSL "$1" -o "$2"
    elif have wget; then
        wget -q -O "$2" "$1"
    elif have uclient-fetch; then
        uclient-fetch -q -O "$2" "$1"
    else
        die "none of curl/wget/uclient-fetch is available" 4
    fi
}

sha_of() { # sha_of <file>
    if have sha256sum; then
        sha256sum "$1" | cut -d' ' -f1
    else
        openssl dgst -sha256 -r "$1" | cut -d' ' -f1
    fi
}

[ "$#" -ge 1 ] || usage
CHECK=0
case "$1" in
    --arches) printf '%s\n' "$CLUB_ARCHES" | tr ' ' '\n'; exit 0 ;;
    --check)  CHECK=1; shift ;;
    -h|--help) usage ;;
esac

[ "$#" -ge 2 ] || usage
VER_IN="$1"; ARCH="$2"; EXT="${3:-apk}"

[ -n "$VER_IN" ] || die "empty tag/version -- this is exactly the bug this script exists to stop"
[ -n "$ARCH" ]   || die "empty arch"
case "$ARCH" in *[!0-9A-Za-z_-]*) die "arch has unexpected characters: '$ARCH'" ;; esac
case "$EXT" in apk|ipk) ;; *) die "unknown extension '$EXT' (want apk or ipk)" ;; esac

VER="$(to_version "$VER_IN")"
[ -n "$VER" ] || die "cannot normalise '$VER_IN' to a version"
case "$VER" in [0-9]*) ;; *) die "version must start with a digit, got '$VER' (from '$VER_IN')" ;; esac
case "$VER" in *[!0-9A-Za-z._]*) die "version has unexpected characters: '$VER'" ;; esac

TAG="$(to_tag "$VER")"
ASSET="${PREFIX}_${VER}_${ARCH}.${EXT}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
URL="${BASE}/${ASSET}"

case " $CLUB_ARCHES " in
    *" $ARCH "*) ;;
    *) printf 'tollgate-release-url: note: %s is not a club arch (%s); older releases may still carry it\n' \
           "$ARCH" "$CLUB_ARCHES" >&2 ;;
esac

if [ "$CHECK" -eq 0 ]; then
    printf '%s\n' "$URL"
    exit 0
fi

TMP="$(mktemp -d)" || die "no mktemp" 4
trap 'rm -rf "$TMP"' EXIT INT TERM

MAN="$TMP/SHA256SUMS"
fetch "$BASE/SHA256SUMS" "$MAN" || die "cannot fetch SHA256SUMS for tag $TAG" 4

EXPECT="$(grep -E "[[:space:]]${ASSET}\$" "$MAN" | head -n 1 | cut -d' ' -f1)"
[ -n "$EXPECT" ] || die "asset is not listed in SHA256SUMS for $TAG: $ASSET" 4

fetch "$URL" "$TMP/$ASSET" || die "asset URL is not fetchable (404 or wrong name): $URL" 4

GOT="$(sha_of "$TMP/$ASSET")"
[ "$GOT" = "$EXPECT" ] || die "sha256 mismatch for $ASSET
  manifest: $EXPECT
  download: $GOT" 4

printf 'OK  %s\n    sha256 %s\n    (matches SHA256SUMS for %s; authenticate the manifest with SHA256SUMS.sig before trusting it)\n' \
    "$URL" "$GOT" "$TAG"
