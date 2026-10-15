#!/bin/sh
# tollgate-release-url.sh -- resolve the tollgate-wrt download URL for a release.
#
# The release TAG and the package asset name are NOT the same string:
#
#     tag   : v0.6.0-rc6                             (leading 'v', hyphens)
#     asset : tollgate-wrt_0.6.0_rc6_aarch64_cortex-a53-mediatek-filogic.apk
#                                                    (no 'v', underscores)
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
# A THIRD failure is why the target argument exists (2026-10-15, Option A):
# the asset name carries the OpenWrt TARGET as well as the arch, because one
# CPU arch serves several targets. `mips_24kc` is both ath79/generic (AR300M
# -lite/-16) and ath79/nand (AR300M -nor/-nand). An arch-only asset name was
# ambiguous -- the two rows collided -- so this script must not guess either:
# the arch alone no longer identifies a URL, and passing one is a hard error
# rather than a URL that 404s on a NAND unit.
#
# This script needs a POSIX shell and nothing else. It never prints a URL it
# cannot construct: empty or malformed input is a hard error, not a warning.
#
# Usage:
#   tollgate-release-url.sh <tag-or-version> <arch> <target> [apk|ipk]
#   tollgate-release-url.sh --check <tag-or-version> <arch> <target> [apk|ipk]
#   tollgate-release-url.sh --arches
#
# Examples:
#   tollgate-release-url.sh v0.6.0-rc6 aarch64_cortex-a53 mediatek-filogic
#   tollgate-release-url.sh 0.6.0_rc6 mips_24kc ath79-generic ipk
#   tollgate-release-url.sh --check v0.6.0-rc6 aarch64_cortex-a53 mediatek-filogic
#
# `--check` downloads the asset, requires it to be listed in the release's
# signed SHA256SUMS, and compares digests. It exits non-zero on any mismatch,
# so it is safe to use as a self-gating step in a handoff.
#
# Exit codes: 0 ok | 2 usage | 3 empty/malformed input | 4 --check failed.

set -u

REPO="${TOLLGATE_RELEASE_REPO:-FreedomTechFeed/packages}"
PREFIX="tollgate-wrt"

# Club arch/target pairs (docs/per-arch-release-assets.md). Old releases also
# carry parked rows; we accept any well-formed arch/target, but we do not
# silently invent one -- and we never resolve an arch to a target, because the
# arch alone does not identify an asset name.
CLUB_ARCH_TARGETS="aarch64_cortex-a53/mediatek-filogic mips_24kc/ath79-generic"

die() { printf 'tollgate-release-url: %s\n' "$1" >&2; exit "${2:-3}"; }

usage() {
    cat >&2 <<EOF
usage: $(basename "$0") <tag-or-version> <arch> <target> [apk|ipk]
       $(basename "$0") --check <tag-or-version> <arch> <target> [apk|ipk]
       $(basename "$0") --arches

  <tag-or-version>  v0.6.0-rc6  or  0.6.0_rc6  (both accepted)
  <arch>            e.g. aarch64_cortex-a53, mips_24kc
  <target>          e.g. mediatek-filogic, ath79-generic, ath79-nand
                    (REQUIRED -- mips_24kc alone is ambiguous: ath79/generic
                     and ath79/nand are different assets)
  [apk|ipk]         apk (OpenWrt 25.12, default) or ipk (24.10)

club arch/target pairs: $CLUB_ARCH_TARGETS

The legacy arch-only forms are REFUSED, not resolved (exit 3):
  $0 <tag> <arch>              -- arch alone does not identify an asset
  $0 <tag> <arch> <apk|ipk>    -- that third positional is an extension, not a
                                  target; it would emit tollgate-wrt_<v>_<arch>-ipk.apk

  $(basename "$0") --self-test   exercise every refusal above and report
                                 refused/accepted per case (exit 1 if any
                                 expected refusal was accepted)

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
    --arches) printf '%s\n' "$CLUB_ARCH_TARGETS" | tr ' ' '\n'; exit 0 ;;
    --check)  CHECK=1; shift ;;
    # Measured, not asserted: every shape this script is supposed to refuse is
    # RUN here, and a case that is (wrongly) accepted fails the whole self-test.
    # The reviewed defect was an exit-0 URL for the legacy (tag, arch, ext) form,
    # so "it is refused" has to be a count of subprocess exit codes, not a claim.
    --self-test)
        shift
        _st_rc=0
        _st_n=0
        # run_case <expect:0|3> <label> <args...>
        run_case() {
            _st_expect="$1"; _st_label="$2"; shift 2
            _st_out=$(sh "$0" "$@" 2>&1); _st_got=$?
            _st_n=$((_st_n + 1))
            if [ "$_st_expect" = 3 ] && [ "$_st_got" -ne 0 ]; then
                printf 'ok  refused: %s (exit %s)\n' "$_st_label" "$_st_got"
            elif [ "$_st_expect" = 0 ] && [ "$_st_got" -eq 0 ]; then
                printf 'ok  emitted: %s\n                   %s\n' "$_st_label" "$_st_out"
            else
                printf 'FAIL %s: expected exit %s, got %s\n     %s\n' \
                    "$_st_label" "$_st_expect" "$_st_got" "$_st_out"
                _st_rc=1
            fi
        }
        # The only accepted shapes: (tag|version, arch, target, [ext]).
        run_case 0 "canonical apk lane"      v0.6.0-rc6 aarch64_cortex-a53 mediatek-filogic
        run_case 0 "canonical ipk lane"      0.6.0_rc6 mips_24kc ath79-generic ipk
        # Refusals. Case 3 is the regression this self-test exists for.
        run_case 3 "no target at all"        v0.6.0-rc6 aarch64_cortex-a53
        run_case 3 "legacy (tag,arch,apk)"   v0.6.0-rc6 aarch64_cortex-a53 apk
        run_case 3 "legacy (tag,arch,ipk)"   0.6.0_rc6 mips_24kc ipk
        run_case 3 "empty tag"               "" aarch64_cortex-a53 mediatek-filogic
        run_case 3 "empty arch"              v0.6.0-rc6 "" mediatek-filogic
        run_case 3 "empty target"            v0.6.0-rc6 aarch64_cortex-a53 ""
        run_case 3 "target = version"        v0.6.0-rc6 aarch64_cortex-a53 v0.6.0-rc6
        run_case 3 "unknown extension"       v0.6.0-rc6 mips_24kc ath79-generic rpm
        run_case 3 "shell metachars in target" v0.6.0-rc6 mips_24kc 'ath79;rm -rf /'
        run_case 3 "shell metachars in arch" v0.6.0-rc6 'a53;id' mediatek-filogic
        run_case 3 "version not starting with a digit" vX.Y mips_24kc ath79-generic
        printf -- '---\ntollgate-release-url: %s case(s), %s\n' \
            "$_st_n" "$([ "$_st_rc" -eq 0 ] && echo 'all refusals held' || echo 'A REFUSAL WAS ACCEPTED')"
        exit "$_st_rc"
        ;;
    -h|--help) usage ;;
esac

# The target argument is REQUIRED, and the old forms are refused loudly rather
# than resolved:
#   * 2 arguments (arch-only) -- the target cannot be guessed at all.
#   * 3 arguments with the EXTENSION in the target slot -- the old handoff form
#     was (tag, arch, ext), so `... mips_24kc ipk` would silently read "ipk" as
#     a target and emit tollgate-wrt_<ver>_mips_24kc-ipk.apk: a plausible URL
#     that 404s, which is precisely the failure class this script exists to
#     stop. A target can never be "apk"/"ipk", so that value is measured and
#     rejected rather than trusted.
# Say so instead of emitting it.
[ "$#" -ge 3 ] || {
    if [ "$#" -eq 2 ]; then
        die "the <target> argument is required: '$2' alone does not identify an asset.
  Since 2026-10-15 the asset name is tollgate-wrt_<version>_<arch>-<target>.<ext>,
  because one arch serves several targets (mips_24kc is ath79/generic AND
  ath79/nand). e.g. $0 $1 $2 ath79-generic"
    fi
    usage
}
VER_IN="$1"; ARCH="$2"; TARGET="$3"; EXT="${4:-apk}"

[ -n "$VER_IN" ] || die "empty tag/version -- this is exactly the bug this script exists to stop"
[ -n "$ARCH" ]   || die "empty arch"
[ -n "$TARGET" ] || die "empty target"
case "$ARCH" in *[!0-9A-Za-z_-]*) die "arch has unexpected characters: '$ARCH'" ;; esac
# `apk`/`ipk` in the target slot is the pre-2026-10-15 (tag, arch, ext) call, not
# a target: refuse it instead of building a URL for a target that cannot exist.
if [ "$TARGET" = apk ] || [ "$TARGET" = ipk ]; then
    die "'$TARGET' is an EXTENSION, not a target -- the legacy (tag, arch, ext) form is refused.
  tollgate-wrt_<version>_<arch>-<target>.<ext> needs an explicit target, e.g.:
    $0 $1 $2 ath79-generic $TARGET"
fi
case "$TARGET" in *[!0-9A-Za-z_-]*) die "target has unexpected characters: '$TARGET'" ;; esac
case "$EXT" in apk|ipk) ;; *) die "unknown extension '$EXT' (want apk or ipk)" ;; esac

VER="$(to_version "$VER_IN")"
[ -n "$VER" ] || die "cannot normalise '$VER_IN' to a version"
case "$VER" in [0-9]*) ;; *) die "version must start with a digit, got '$VER' (from '$VER_IN')" ;; esac
case "$VER" in *[!0-9A-Za-z._]*) die "version has unexpected characters: '$VER'" ;; esac

TAG="$(to_tag "$VER")"
ASSET="${PREFIX}_${VER}_${ARCH}-${TARGET}.${EXT}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
URL="${BASE}/${ASSET}"

case " $CLUB_ARCH_TARGETS " in
    *" $ARCH/$TARGET "*) ;;
    *) printf 'tollgate-release-url: note: %s/%s is not a club arch/target pair (%s); older releases may still carry it\n' \
           "$ARCH" "$TARGET" "$CLUB_ARCH_TARGETS" >&2 ;;
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
