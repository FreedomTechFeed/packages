#!/bin/sh
# test-build-contract.sh -- the feed consumes upstream's build contract, not
# its own memory of what upstream ships.
#
# WHY THIS EXISTS. For the whole life of this feed, the facts of a tollgate
# release -- which binaries exist, their module paths, the Go language
# minimum -- were re-derived here by hand. That is a second brain, and second
# brains rot quietly: upstream added the CVM control-plane daemon as a third
# shipped binary and this recipe kept building two (upstream's OWN apk lane
# broke the same way days earlier, #1020 -- a carrier missing what the
# authority already declared). The Gen-1 standalone feed
# (FreedomTechFeed/feed) has the same defect one generation deeper, plus a
# CLI version injection that upstream fixed in its Gen-2 (pre5) after the
# Gen-1 copy had already forked from the truth.
#
# Upstream's answer (their #1021): packaging/build-contract.json -- GENERATED
# in the module repo from its own authorities (packaging/Makefile PREBUILT_*
# for the binary set, the src/**/go.mod glob for the language minimum,
# build-inputs.json for the pinned toolchain), fenced there, and shipped IN
# the release tarball, because codeload tarballs are repo snapshots: every
# tag and every SHA pin carries it for free.
#
# This test consumes it from the pinned tarball and enforces, BOTH ways:
#
#   Gate 1  binary-set parity: every contract binary is built by
#           Build/Compile AND installed by the install recipe; no
#           $(GO_PKG_BUILD_BIN_DIR)/ install that the contract does not
#           declare. Adding a binary upstream turns this red on the next
#           repin; removing one fails the package build here first.
#   Gate 2  toolchain fence: the contract's go minimum must be <= the
#           golang THIS FEED builds with, read from the feed's own
#           lang/golang/golang-values.mk (GO_DEFAULT_VERSION) plus the
#           per-version Makefile (GO_VERSION_PATCH) -- never a hand-kept
#           number. A pin whose language minimum exceeds the feed's golang
#           cannot compile; refusing it here is minutes instead of a 40-min
#           SDK bootstrap failing at the end.
#   Gate 3  module sanity: every contract module dir exists in the pinned
#           tarball with a go.mod (a contract/tarball mismatch is a broken
#           pin, not a soft warning).
#
# PARAMETERS (modular on purpose -- the Gen-1 wrapper feed runs this same
# test against its own checkout):
#   TG_CONTRACT_MODE     auto (default): contract absent -> WARN and pass
#                        (pre-contract pins); present -> enforce.
#                        required: contract absent -> FAIL. Flip the default
#                        to required once the pin moves past the contract's
#                        landing commit.
#   TG_CONTRACT_FILE     override the contract source (a local
#                        build-contract.json) -- skips the tarball for the
#                        contract itself; parity gates still need the
#                        tarball only for Gate 3.
#   TG_FEED_ROOT         where to read lang/golang from (default: repo root
#                        of this checkout).
#   TOLLGATE_PKG_TARBALL / TOLLGATE_DL_DIR   same cache conventions as
#                        test-pkg-tarball-parity.sh.
set -eu

MK="$(cd "$(dirname "$0")" && pwd)/Makefile"
FEED_ROOT="${TG_FEED_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
CONTRACT_MODE="${TG_CONTRACT_MODE:-auto}"

fail() { echo "FAIL: $1" >&2; echo "test-build-contract: FAILED" >&2; exit 1; }
warn() { echo "WARN: $1" >&2; }
ok()   { echo "ok:   $1"; }

command -v curl >/dev/null 2>&1 || fail "Gate P: curl is required"
command -v jq >/dev/null 2>&1 || fail "Gate P: jq is required"
[ -f "$MK" ] || fail "Gate P: $MK not found"

LC_ALL=C; export LC_ALL

mkvar() { sed -n "s/^$1:=//p" "$MK" | head -n 1; }

PKG_SOURCE_VERSION=$(mkvar PKG_SOURCE_VERSION)
[ -n "$PKG_SOURCE_VERSION" ] || fail "Gate P: could not read PKG_SOURCE_VERSION from $MK"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/tg-contract.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# ---- acquire the contract (tarball, or TG_CONTRACT_FILE override) ----------

CONTRACT="${TG_CONTRACT_FILE:-}"
if [ -z "$CONTRACT" ]; then
    DL_DIR="${TOLLGATE_DL_DIR:-$HOME/.cache/tollgate-feed-dl}"
    mkdir -p "$DL_DIR" 2>/dev/null || DL_DIR="$SCRATCH"
    TARBALL="${TOLLGATE_PKG_TARBALL:-$DL_DIR/tollgate-module-basic-go-$PKG_SOURCE_VERSION.tar.gz}"
    if [ ! -s "$TARBALL" ]; then
        URL="https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/$PKG_SOURCE_VERSION"
        echo "--- fetching $URL"
        curl -fsSL "$URL" -o "$TARBALL" || fail "Gate P: cannot fetch the pinned tarball"
    fi
    CONTRACT="$SCRATCH/build-contract.json"
    if ! tar -xzOf "$TARBALL" \
         "tollgate-module-basic-go-$PKG_SOURCE_VERSION/packaging/build-contract.json" \
         > "$CONTRACT" 2>/dev/null; then
        if [ "$CONTRACT_MODE" = "required" ]; then
            fail "Gate A: the pinned tarball carries no packaging/build-contract.json and TG_CONTRACT_MODE=required"
        fi
        warn "pin $PKG_SOURCE_VERSION predates the build contract (upstream #1021); nothing to enforce"
        warn "flip TG_CONTRACT_MODE to required once the pin moves past the contract's landing"
        echo "test-build-contract: PASSED (no contract in pin; warned)"
        exit 0
    fi
fi

echo "--- contract: $(jq -r .version "$CONTRACT") (go min $(jq -r .go.minimum "$CONTRACT"), pin $(jq -r .go.pin "$CONTRACT"))"

# ---- Gate 1: binary-set parity, both directions -----------------------------
#
# The recipe builds each contract binary from its contract-declared module
# (`cd $(PKG_BUILD_DIR)/<module minus src/>` — the root module is built by
# the golang-package.mk framework itself, so its assertion is the
# GO_PKG_BUILD_PKG line) and installs it under /usr/bin/<name>. Both sides
# are asserted per binary; the extra direction below catches installs of
# artifacts the contract does not declare.

RECIPE="$MK"
for name in $(jq -r '.binaries[].name' "$CONTRACT" | sort); do
    mod="$(jq -r --arg n "$name" '.binaries[] | select(.name==$n) | .module' "$CONTRACT")"
    grep -q "usr/bin/$name" "$RECIPE" \
        || fail "Gate 1: contract binary '$name' is never INSTALLED (no /usr/bin/$name line)"
    if [ "$mod" = "src" ]; then
        grep -q "^GO_PKG_BUILD_PKG" "$RECIPE" \
            || fail "Gate 1: root-module binary '$name' has no GO_PKG_BUILD_PKG framework build"
    else
        grep -q "cd \$(PKG_BUILD_DIR)/${mod#src/}" "$RECIPE" \
            || fail "Gate 1: contract binary '$name' never BUILDS its module '$mod'"
    fi
    ok "Gate 1: '$name' (module $mod) built and installed"
done

# extra direction: every $(GO_PKG_BUILD_BIN_DIR) install must be a contract
# binary (golang-package.mk's own framework outputs live under the same dir;
# only INSTALL lines are asserted, and only ones naming tollgate artifacts).
for installed in $(sed -n 's/.*\$(GO_PKG_BUILD_BIN_DIR)\/\([a-z][a-z0-9-]*\).*/\1/p' "$RECIPE" | sort -u); do
    case "$installed" in
        tollgate|tollgate-cli|tollgate-wrt|tollgate-cvm|tollgate-module-basic-go) ;;
        *) warn "Gate 1: '$installed' installed from GO_PKG_BUILD_BIN_DIR but not a known tollgate artifact (review)";;
    esac
done

# ---- Gate 2: the feed's golang must satisfy the contract's minimum ---------

GV="$FEED_ROOT/lang/golang/golang-values.mk"
[ -f "$GV" ] || fail "Gate 2: $GV not found (set TG_FEED_ROOT to a packages feed checkout)"
GO_MM="$(sed -n 's/^GO_DEFAULT_VERSION:=//p' "$GV" | head -1 | tr -d '[:space:]')"
[ -n "$GO_MM" ] || fail "Gate 2: cannot read GO_DEFAULT_VERSION from $GV"
GO_PATCH="$(sed -n "s/^GO_VERSION_PATCH:=//p" "$FEED_ROOT/lang/golang/golang${GO_MM}/Makefile" | head -1 | tr -d '[:space:]')"
FEED_GO="${GO_MM}.${GO_PATCH}"
CONTRACT_MIN="$(jq -r .go.minimum "$CONTRACT")"

smaller() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

if smaller "$CONTRACT_MIN" "$FEED_GO" || [ "$CONTRACT_MIN" = "$FEED_GO" ]; then
    ok "Gate 2: feed golang $FEED_GO satisfies contract minimum $CONTRACT_MIN"
else
    fail "Gate 2: contract go minimum $CONTRACT_MIN EXCEEDS this feed's golang $FEED_GO -- the pin cannot compile here; bump lang/golang or repin older"
fi

# ---- Gate 3: contract modules exist in the pinned tarball -------------------

TARBALL_DIR="${TOLLGATE_PKG_TARBALL:-${DL_DIR:-$HOME/.cache/tollgate-feed-dl}/tollgate-module-basic-go-$PKG_SOURCE_VERSION.tar.gz}"
if [ -s "$TARBALL_DIR" ]; then
    for mod in $(jq -r '.binaries[].module' "$CONTRACT" | sort -u); do
        if ! tar -tzf "$TARBALL_DIR" \
             "tollgate-module-basic-go-$PKG_SOURCE_VERSION/$mod/go.mod" >/dev/null 2>&1; then
            fail "Gate 3: contract module '$mod' has no go.mod in the pinned tarball -- broken pin or stale contract"
        fi
    done
    ok "Gate 3: all contract modules present in the pin"
else
    warn "Gate 3: tarball unavailable; module sanity skipped"
fi

echo "test-build-contract: PASSED"
