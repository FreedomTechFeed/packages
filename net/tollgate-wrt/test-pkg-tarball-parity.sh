#!/bin/sh
# test-pkg-tarball-parity.sh -- both-directions drift guard between the feed's
# install recipe and the module tarball it installs its runtime files from.
#
# WHY THIS EXISTS (measured on hardware, pre17): the published pre16 package did
# NOT ship packaging/files/etc/nftables.d/31-admin-board-not-guest-reachable.nft.
# The file WAS in the module tarball the feed builds from (module #566, merged),
# but the install recipe enumerated the nftables.d files by hand -- exactly two
# of them -- so the third was silently dropped. On the bench MT3000
# /etc/nftables.d/ held only 10-custom-filter-chains.nft, 20-nds-enforce.nft,
# 30-backend-firewall.nft and README, and :8090 still answered HTTP 200 from a
# br-lan (guest) client: the exact thing #566 was merged to prevent. Nothing
# failed -- the package built, release-publish went green, SHA256SUMS verified.
# A hand-maintained install list has no way to notice a new upstream file.
#
# The recipe now stages the WHOLE module-owned etc/nftables.d/ directory (glob,
# not a list). This test makes that structural instead of conventional: it
# compares the SET of files the recipe stages out of $(PKG_TARBALL_DIR) against
# the pinned tarball's own packaging/files/ tree, and fails in BOTH directions.
#
#   missing direction -- a $(PKG_TARBALL_DIR)/... path the recipe installs that
#     the pinned tarball does not contain. That is a hard package-build failure
#     (the welcome.html class: module #517 deleted the file, so the old install
#     line would have failed the build outright -- caught only by a manual
#     path-by-path check on the pre15 round, which is how this file exists).
#   extra direction -- a file in the tarball's packaging/files/ that the recipe
#     never stages. That is the pre16 defect verbatim.
#
# Gates:
#   A. the tarball is present and its sha256 equals the Makefile's PKG_HASH (the
#      pin/hash pair is the identity of everything measured below; it also makes
#      a moved pin without a recalibrated hash fail here rather than in CI)
#   B. the tarball's own VERSION file equals PKG_SOURCE_TAG -- the invariant the
#      Makefile's version block documents. A stale tag is a live defect, not a
#      mislabel: it writes a setup marker no upstream build writes and sends an
#      upgrade down 99-tollgate-setup's same-version path, where the new
#      full-setup work never runs.
#   C. missing direction: every $(PKG_TARBALL_DIR) install reference in the
#      recipe resolves inside the tarball (globs expanded)
#   D. extra direction, guarded dir: tarball etc/nftables.d/ == staged
#      etc/nftables.d/, EXACTLY, with NO exclusions -- the directory the pre16
#      defect lived in gets no benefit of the doubt
#   E. extra direction, whole tree: every tarball packaging/files/ file outside
#      the single documented exclusion (see below) must be staged
#   F. the exclusion is not a hole: every file under the excluded tree must have
#      a feed-side counterpart in vendor.lock.json
#   G. the exclusion must never be widened over a guarded directory
#   H. the install recipe carries no $$shell-variable use: the OpenWrt package
#      path expands the install define MORE THAN ONCE, so `$$name` reaches the
#      shell already partially eaten. Measured 2026-09-25 in the multi-arch SDK
#      build (mips64_octeonplus), where a for-loop staging the nftables
#      fragments executed as `install -m0644 "ft"` — `$$nft` became `$nft` and
#      then `$n` (empty) + `ft` — and failed the package build. The guarded
#      directory is staged by wildcard instead, which needs no shell variable.
#   I. the postinst APPLIES what the uci-defaults only WRITE, in the module's
#      own order. A shipped config fragment is not an active control: the recipe
#      runs /etc/uci-defaults/ on a RUNNING router, and firewall/dnsmasq/uhttpd/
#      nodogsplash keep the state they loaded at their own start unless the
#      install reloads them. Measured on the bench GL-MT3000 with the published
#      pre17 package: 31-admin-board-not-guest-reachable.nft was on disk
#      byte-identical to the apk and the guard chain did not exist, so :8090 and
#      :8443 still answered HTTP 200 from a br-lan (guest) client — the exact
#      thing that fragment ships to prevent — until a manual `fw4 reload`. The
#      module's own packaging/Makefile has always reloaded the services; only
#      this feed's recipe did not, which is why Gate I compares the two bodies
#      AT THE PIN instead of trusting either: the ordered service-action
#      sequence of the module's postinst must appear, in that order, in the
#      feed's, the firewall reload must follow the last uci-defaults invocation
#      (the ordering IS the fix), and the nodogsplash restart must follow the
#      firewall reload (an fw4 reload flushes ND's injected chains). A copy that
#      silently drops or reorders a reload fails here instead of on hardware.
#   J. the pair gate: the vendored 92 (from the portal pin) and the pinned
#      module tarball's 99-tollgate-setup are the TWO writers of
#      uhttpd.main.redirect_https, and the install order decides which lands
#      last (the module's postinst runs the uci-defaults as 90, 99, 92 -- 92
#      last there; numeric uci-defaults order at boot is 90, 92, 99 -- 99 last
#      there). Two writers on one DERIVED value are safe only while they
#      evaluate the SAME rule: the module CLI's coverage check, `tollgate ssl
#      covers`. Measured counter-example (bench MT3000, pre17, 2026-09-26): the
#      board's :8443 carried the OpenWrt image's placeholder certificate
#      (CN=OpenWrt, SAN DNS:OpenWrt) and :8090 redirected to it, so every admin
#      login showed a hard certificate error -- with each writer's own premise
#      satisfied. J.a each script evaluates the shared predicate; J.b each
#      writes an explicit value in BOTH directions; J.c every
#      redirect_https='1' is armed by the coverage predicate -- either the
#      condition names it, or it tests a flag only the predicate can arm (the
#      module #612 hoist; the Gate J block lists the accepted shapes and the
#      control that keeps the extension from accepting everything) -- and never by
#      an existence test of the placeholder (the pre17 defect); J.d the
#      two fingerprints are identical, so the writers cannot drift onto two
#      different checkers. The two files are at DIFFERENT pins on purpose (92 is
#      vendored from vendor.lock.json -> portal_commit, 99 comes from the module
#      pin's tarball); the gate compares them where the recipe actually gets
#      them, which is what makes a half-landed re-pin fail here.
#
# THE ONE DOCUMENTED EXCLUSION: packaging/files/tollgate-captive-portal-site/.
# The module ships a checked-in, ASSET-LESS copy of the guest portal (the vite
# assets are gitignored upstream, so the copy could never be complete), and
# docs/architecture/portal-bundle-ownership.md collapses that duplicate onto a
# single producer: the feed builds the portal at the pinned commit
# (vendor.lock.json -> portal_commit) and installs THAT. Staging the module's
# copy as well would ship a second, older portal -- the pre10 admin-regression
# class. Gate F keeps the exclusion honest by requiring a lock entry per file,
# so a NEW module file in that tree still fails loudly instead of vanishing.
# The exclusion is one fixed prefix and Gate G refuses it over a guarded dir.
#
# Exit status: 0 = pass, 1 = fail. Needs git, awk, tar, find, sort, comm,
# sha256sum and python3 (python3 only to read vendor.lock.json and to compare the
# two postinst action sequences, matching test-devendored.sh's dependency set).
#
# Env overrides:
#   TOLLGATE_PKG_TARBALL=<file>  use this tarball instead of the cached download
#   TOLLGATE_DL_DIR=<dir>        tarball cache (default $HOME/.cache/tollgate-feed-dl)
#
# No transfer: the tarball is a 1.1 MB codeload download, cached after first use
# so repeat runs are offline.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FEED="$ROOT/net/tollgate-wrt"
MK="$FEED/Makefile"
LOCK="$FEED/vendor.lock.json"
FAIL=0

# The directory the pre16 defect lived in. Guarded with no exclusions (Gate D).
GUARD_PREFIX="etc/nftables.d/"
# The one documented, audited exclusion (Gates E/F/G). See the header.
EXCLUDE_PREFIX="tollgate-captive-portal-site/"

ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

if [ ! -f "$MK" ]; then
    echo "FAIL: $MK not found" >&2
    echo "test-pkg-tarball-parity: FAILED" >&2
    exit 1
fi

# LC_ALL=C so sort/comm agree on collation (the sets contain '-', '.' and '/')
LC_ALL=C
export LC_ALL

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/tg-pkg-parity.XXXXXX") || {
    echo "FAIL: could not create a scratch dir" >&2
    exit 1
}
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

mkvar() {
    sed -n "s/^$1:=//p" "$MK" | head -n 1
}

PKG_VERSION=$(mkvar PKG_VERSION)
PKG_SOURCE_VERSION=$(mkvar PKG_SOURCE_VERSION)
PKG_SOURCE_TAG=$(mkvar PKG_SOURCE_TAG)
PKG_SOURCE=$(mkvar PKG_SOURCE)
PKG_SOURCE_URL=$(mkvar PKG_SOURCE_URL)
PKG_HASH=$(mkvar PKG_HASH)

# PKG_SOURCE / PKG_SOURCE_URL are written in terms of other make variables, so
# substitute the ones this test knows. The Makefile carries these two forms:
#   PKG_SOURCE:=tollgate-module-basic-go-$(PKG_SOURCE_VERSION).tar.gz
#   PKG_SOURCE_URL:=https://codeload.github.com/.../tar.gz/$(PKG_SOURCE_VERSION)?
# (a bare $(NAME) form; there is no ifdef/${...} use to worry about here).
mksubst() {
    printf '%s' "$1" | awk -v sv="$PKG_SOURCE_VERSION" -v pv="$PKG_VERSION" -v st="$PKG_SOURCE_TAG" '
        {
            gsub(/\$\(PKG_SOURCE_VERSION\)/, sv)
            gsub(/\$\(PKG_VERSION\)/, pv)
            gsub(/\$\(PKG_SOURCE_TAG\)/, st)
            printf "%s", $0
        }'
}
PKG_SOURCE=$(mksubst "$PKG_SOURCE")
PKG_SOURCE_URL=$(mksubst "$PKG_SOURCE_URL")


for v in PKG_VERSION PKG_SOURCE_VERSION PKG_SOURCE_TAG PKG_SOURCE PKG_SOURCE_URL PKG_HASH; do
    eval "val=\$$v"
    if [ -z "$val" ]; then
        echo "FAIL: could not read $v from $MK" >&2
        echo "test-pkg-tarball-parity: FAILED" >&2
        exit 1
    fi
done
echo "--- pinned source: $PKG_SOURCE_VERSION (PKG_VERSION=$PKG_VERSION, PKG_SOURCE_TAG=$PKG_SOURCE_TAG)"

# ---------------------------------------------------------------- Gate A ----
# Acquire the tarball and prove it is the one the Makefile pins.
TARBALL="${TOLLGATE_PKG_TARBALL:-}"
if [ -z "$TARBALL" ]; then
    DL_DIR="${TOLLGATE_DL_DIR:-$HOME/.cache/tollgate-feed-dl}"
    if ! mkdir -p "$DL_DIR"; then
        fail "Gate A: cannot create the tarball cache dir $DL_DIR"
        DL_DIR=""
    fi
    if [ -n "$DL_DIR" ]; then
        TARBALL="$DL_DIR/$PKG_SOURCE"
        if [ ! -f "$TARBALL" ]; then
            # The trailing '?' in PKG_SOURCE_URL is load-bearing: download.pl
            # appends "/$PKG_SOURCE" to it, turning that suffix into a query
            # string codeload ignores so the COMMIT SHA stays the ref. Replay
            # exactly that construction.
            URL="$PKG_SOURCE_URL$PKG_SOURCE"
            PART="$TARBALL.part.$$"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL -o "$PART" "$URL" || rm -f "$PART"
            elif command -v wget >/dev/null 2>&1; then
                wget -q -O "$PART" "$URL" || rm -f "$PART"
            else
                fail "Gate A: neither curl nor wget available to fetch $URL"
            fi
            if [ -f "$PART" ]; then
                mv "$PART" "$TARBALL"
            elif [ "$FAIL" = 0 ]; then
                fail "Gate A: could not download $URL (offline? set TOLLGATE_PKG_TARBALL=<file>)"
            fi
        fi
    fi
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

TOP=""
if [ -n "$TARBALL" ] && [ -f "$TARBALL" ]; then
    ACTUAL=$(sha256_of "$TARBALL")
    if [ "$ACTUAL" = "$PKG_HASH" ]; then
        ok "Gate A: PKG_HASH matches $(basename "$TARBALL") (${ACTUAL})"
    else
        fail "Gate A: PKG_HASH mismatch for $(basename "$TARBALL")"
        echo "      PKG_HASH: $PKG_HASH" >&2
        echo "      actual  : $ACTUAL" >&2
    fi
    mkdir -p "$SCRATCH/xt"
    if tar -xzf "$TARBALL" -C "$SCRATCH/xt" >/dev/null 2>&1; then
        TOP=$(find "$SCRATCH/xt" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        ok "Gate A: extracted $(basename "${TOP:-$TARBALL}")"
    else
        fail "Gate A: could not extract $(basename "$TARBALL")"
    fi
else
    fail "Gate A: no tarball available for $PKG_SOURCE_VERSION (see the message above)"
fi

# $PKG_FILES is the module-owned runtime tree; $TOP is the tarball root the
# recipe's $(PKG_TARBALL_DIR) points at. Recipe references are written as
# "packaging/files/…", so they resolve against $TOP, not $PKG_FILES.
PKG_FILES="$TOP/packaging/files"
if [ -z "$TOP" ] || [ ! -d "$PKG_FILES" ]; then
    fail "Gate A: the tarball carries no packaging/files/ tree -- cannot audit parity"
    echo "test-pkg-tarball-parity: FAILED" >&2
    exit 1
fi

# ---------------------------------------------------------------- Gate B ----
if [ ! -f "$TOP/VERSION" ]; then
    fail "Gate B: the tarball has no repo-root VERSION file"
else
    TARBALL_VERSION=$(sed -n '1p' "$TOP/VERSION" | tr -d '[:space:]')
    if [ "$TARBALL_VERSION" = "$PKG_SOURCE_TAG" ]; then
        ok "Gate B: tarball VERSION == PKG_SOURCE_TAG ($PKG_SOURCE_TAG)"
    else
        fail "Gate B: PKG_SOURCE_TAG does not match the pinned tarball's VERSION"
        echo "      PKG_SOURCE_TAG : $PKG_SOURCE_TAG" >&2
        echo "      tarball VERSION: $TARBALL_VERSION" >&2
    fi
fi

# ------------------------------- the two sets -------------------------------
# Module-side set: every file the tarball ships under packaging/files/.
( cd "$PKG_FILES" && find . -type f -print ) | sed 's|^\./||' | LC_ALL=C sort > "$SCRATCH/mod.txt"

# Staged set: expand every $(PKG_TARBALL_DIR)/... reference OUTSIDE comments,
# exactly as the recipe's shell would (globs included). Comment lines are
# skipped so documentation that mentions a path cannot count as an install.
awk -v pfx='$(PKG_TARBALL_DIR)/' '
    /^[[:space:]]*#/ { next }
    {
        line = $0
        while (match(line, /\$\(PKG_TARBALL_DIR\)\/[^[:space:];]+/)) {
            ref = substr(line, RSTART + length(pfx), RLENGTH - length(pfx))
            printf "%d %s\n", NR, ref
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$MK" > "$SCRATCH/refs.txt"

if [ ! -s "$SCRATCH/refs.txt" ]; then
    fail "the install recipe references \$(PKG_TARBALL_DIR) nowhere -- did the recipe change shape?"
fi

: > "$SCRATCH/staged.txt"
: > "$SCRATCH/unresolved.txt"
while read -r ln ref; do
    [ -n "${ref:-}" ] || continue
    found=0
    # unquoted on purpose: the shell expands the glob, like the recipe does
    # shellcheck disable=SC2086
    set -- $TOP/$ref
    for hit in "$@"; do
        [ -f "$hit" ] || continue
        found=1
        printf '%s\n' "${hit#"$PKG_FILES"/}" >> "$SCRATCH/staged.txt"
    done
    if [ "$found" = 0 ]; then
        printf 'Makefile:%s  %s\n' "$ln" "$ref" >> "$SCRATCH/unresolved.txt"
    fi
done < "$SCRATCH/refs.txt"
LC_ALL=C sort -u "$SCRATCH/staged.txt" -o "$SCRATCH/staged.txt"

n_refs=$(wc -l < "$SCRATCH/refs.txt" | tr -d ' ')
n_staged=$(wc -l < "$SCRATCH/staged.txt" | tr -d ' ')
n_mod=$(wc -l < "$SCRATCH/mod.txt" | tr -d ' ')
echo "--- $n_refs \$(PKG_TARBALL_DIR) install reference(s) -> $n_staged staged file(s); tarball ships $n_mod file(s)"

# ---------------------------------------------------------------- Gate C ----
# missing direction #1: an install reference the tarball cannot satisfy is a
# package-build failure at this pin.
if [ -s "$SCRATCH/unresolved.txt" ]; then
    n=$(wc -l < "$SCRATCH/unresolved.txt" | tr -d ' ')
    fail "Gate C: $n \$(PKG_TARBALL_DIR) install reference(s) resolve to nothing in the pinned tarball (guaranteed package-build failure)"
    sed 's/^/      /' "$SCRATCH/unresolved.txt" >&2
else
    ok "Gate C: all $n_refs \$(PKG_TARBALL_DIR) install reference(s) resolve inside the pin's tarball"
fi

# ---------------------------------------------------------------- Gate D ----
# extra direction, guarded dir: exact set equality, no exclusions.
grep "^$GUARD_PREFIX" "$SCRATCH/mod.txt" > "$SCRATCH/guard_mod.txt" || true
grep "^$GUARD_PREFIX" "$SCRATCH/staged.txt" > "$SCRATCH/guard_staged.txt" || true
if [ ! -s "$SCRATCH/guard_mod.txt" ]; then
    fail "Gate D: the tarball ships nothing under $GUARD_PREFIX -- the guard has lost its target"
else
    comm -23 "$SCRATCH/guard_mod.txt" "$SCRATCH/guard_staged.txt" > "$SCRATCH/guard_missing.txt"
    comm -13 "$SCRATCH/guard_mod.txt" "$SCRATCH/guard_staged.txt" > "$SCRATCH/guard_extra.txt"
    if [ -s "$SCRATCH/guard_missing.txt" ]; then
        n=$(wc -l < "$SCRATCH/guard_missing.txt" | tr -d ' ')
        fail "Gate D: $n file(s) ship in the tarball's $GUARD_PREFIX but are NOT staged by the install recipe (the pre16 defect)"
        sed 's/^/      NOT SHIPPED: /' "$SCRATCH/guard_missing.txt" >&2
    fi
    if [ -s "$SCRATCH/guard_extra.txt" ]; then
        n=$(wc -l < "$SCRATCH/guard_extra.txt" | tr -d ' ')
        fail "Gate D: $n staged file(s) under $GUARD_PREFIX are NOT in the tarball any more"
        sed 's/^/      STALE INSTALL LINE: /' "$SCRATCH/guard_extra.txt" >&2
    fi
    if [ ! -s "$SCRATCH/guard_missing.txt" ] && [ ! -s "$SCRATCH/guard_extra.txt" ]; then
        n=$(wc -l < "$SCRATCH/guard_mod.txt" | tr -d ' ')
        ok "Gate D: $GUARD_PREFIX parity exact both ways ($n file(s), 0 exclusions)"
    fi
fi

# ------------------------------------------------------------ Gates E/F/G ----
comm -13 "$SCRATCH/staged.txt" "$SCRATCH/mod.txt" > "$SCRATCH/extra.txt"
grep -v "^$EXCLUDE_PREFIX" "$SCRATCH/extra.txt" > "$SCRATCH/extra_unguarded.txt" || true
grep "^$EXCLUDE_PREFIX" "$SCRATCH/extra.txt" > "$SCRATCH/extra_excluded.txt" || true

# Gate E: nothing outside the one documented exclusion may go unshipped.
if [ -s "$SCRATCH/extra_unguarded.txt" ]; then
    n=$(wc -l < "$SCRATCH/extra_unguarded.txt" | tr -d ' ')
    fail "Gate E: $n tarball file(s) outside the documented exclusion are never staged (the package would silently not ship them)"
    sed 's/^/      NOT SHIPPED: /' "$SCRATCH/extra_unguarded.txt" >&2
else
    ok "Gate E: every tarball packaging/files/ file outside '$EXCLUDE_PREFIX' is staged"
fi

# Gate F: the exclusion must be covered file-by-file by the feed's own producer
# (the CI-built portal bundle pinned in vendor.lock.json).
if [ -s "$SCRATCH/extra_excluded.txt" ]; then
    if [ ! -f "$LOCK" ]; then
        fail "Gate F: $LOCK is missing -- cannot prove the excluded tree is shipped from somewhere"
    else
        python3 -c '
import json, sys
lock = json.load(open(sys.argv[1]))
for path in lock.get("files", {}):
    print(path.split("net/tollgate-wrt/files/", 1)[-1])
' "$LOCK" | LC_ALL=C sort > "$SCRATCH/lock.txt"
        n_uncovered=0
        uncovered=""
        while read -r f; do
            [ -n "$f" ] || continue
            if ! grep -qx "$f" "$SCRATCH/lock.txt"; then
                n_uncovered=$((n_uncovered + 1))
                uncovered="$uncovered$f
"
            fi
        done < "$SCRATCH/extra_excluded.txt"
        if [ "$n_uncovered" -gt 0 ]; then
            fail "Gate F: $n_uncovered excluded tarball file(s) have NO vendor.lock.json counterpart, so nothing else ships them either"
            printf '%s' "$uncovered" | sed 's/^/      UNSHIPPED: /' >&2
        else
            n=$(wc -l < "$SCRATCH/extra_excluded.txt" | tr -d ' ')
            ok "Gate F: all $n excluded $EXCLUDE_PREFIX file(s) have a vendor.lock.json counterpart (built in CI from the portal pin)"
        fi
    fi
fi

# Gate G: the exclusion is a fixed prefix for a known build-output tree; it must
# never be widened over a directory the module owns and the package installs.
if grep -q "^$GUARD_PREFIX" "$SCRATCH/extra_excluded.txt" 2>/dev/null; then
    fail "Gate G: the exclusion '$EXCLUDE_PREFIX' now swallows $GUARD_PREFIX, which must never be excluded"
else
    ok "Gate G: the exclusion '$EXCLUDE_PREFIX' does not cover the guarded '$GUARD_PREFIX'"
fi

# ---------------------------------------------------------------- Gate H ----
# No shell variables in the install recipe. The OpenWrt package path expands this
# define more than once, so `$$name` arrives at the shell already eaten (see the
# header). Only the two-dollar form is flagged: the repo's legitimate loop idiom
# uses four times the dollars ($$$$$$$${var}, utils/collectd/Makefile). Comment
# lines are skipped, so the recipe may keep documenting the trap.
awk '
    /^define Package\/tollgate-wrt\/install$/ { inrec = 1; next }
    inrec && /^endef$/ { exit }
    !inrec { next }
    /^[[:space:]]*#/ { next }
    /\$\$[A-Za-z_]/ { printf "%d: %s\n", NR, $0 }
' "$MK" > "$SCRATCH/shelldollar.txt"
if [ -s "$SCRATCH/shelldollar.txt" ]; then
    n=$(wc -l < "$SCRATCH/shelldollar.txt" | tr -d ' ')
    fail "Gate H: $n install-recipe line(s) use a \$\$shell-variable, which the OpenWrt package path expands away before the shell sees it (stage by wildcard/plain path instead)"
    sed 's/^/      /' "$SCRATCH/shelldollar.txt" >&2
else
    ok "Gate H: no \$\$shell-variable use in the install recipe"
fi

# ---------------------------------------------------------------- Gate I ----
# The feed postinst must APPLY the config, the way the module's own postinst
# does, at the SAME pin. See the header: the published pre17 package shipped
# 31-admin-board-not-guest-reachable.nft, the guard chain did not exist after the
# install, and :8090/:8443 answered 200 from br-lan until a manual fw4 reload.
#
# Body extraction: the define bodies, comment lines dropped (a comment that
# names a command is documentation, never an execution).
extract_define() {   # $1=makefile $2=ere matching the define name
    awk -v want="$2" '
        !inb && $0 ~ ("^define[[:space:]]+" want "[[:space:]]*$") { inb = 1; next }
        inb && /^endef[[:space:]]*$/ { exit }
        inb { print }
    ' "$1"
}

# Ordered service actions, one per line, comments skipped. Recognised shapes:
#   /etc/init.d/<svc> <verb>          -> init:<svc>:<verb>
#   .../uci-defaults/<script>         -> uci-defaults
#   wifi reload                       -> wifi:reload
# Only the first match on a line is recorded: the recipe runs one action per line
# and a line carrying two would be a rewrite of the block, not a port of it.
actions_of() {
    awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            if (line ~ /\/etc\/uci-defaults\//) { print "uci-defaults"; next }
            if (match(line, /\/etc\/init\.d\/[A-Za-z0-9_.-]+[[:space:]]+(enable|disable|restart|reload|start|stop)/)) {
                m = substr(line, RSTART, RLENGTH)
                gsub(/[[:space:]]+/, ":", m)
                sub(/^\/etc\/init\.d\//, "init:", m)
                print m; next
            }
            if (line ~ /(^|[^A-Za-z0-9_-])wifi[[:space:]]+reload([^A-Za-z0-9_-]|$)/) { print "wifi:reload"; next }
        }
    '
}

# Shell functions the body defines (helper parity: the port carries the helpers
# it calls, e.g. wait_for_iface).
functions_of() {
    awk '
        /^[[:space:]]*#/ { next }
        match($0, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {
            name = substr($0, RSTART, RLENGTH)
            gsub(/[[:space:]()]/, "", name)
            print name
            next
        }
    '
}

MOD_MK="$TOP/packaging/Makefile"
if [ ! -f "$MOD_MK" ]; then
    fail "Gate I: the pinned tarball has no packaging/Makefile -- cannot compare the postinsts"
else
    extract_define "$MOD_MK" 'Package/.*/postinst' > "$SCRATCH/mod-postinst.txt"
    extract_define "$MK" 'Package/tollgate-wrt/postinst' > "$SCRATCH/feed-postinst.txt"

    if [ ! -s "$SCRATCH/mod-postinst.txt" ]; then
        fail "Gate I: no 'define Package/<name>/postinst' body in the pinned tarball's packaging/Makefile"
    elif [ ! -s "$SCRATCH/feed-postinst.txt" ]; then
        fail "Gate I: no 'define Package/tollgate-wrt/postinst' body in $MK"
    else
        actions_of < "$SCRATCH/mod-postinst.txt" > "$SCRATCH/mod-actions.txt"
        actions_of < "$SCRATCH/feed-postinst.txt" > "$SCRATCH/feed-actions.txt"
        functions_of < "$SCRATCH/mod-postinst.txt" > "$SCRATCH/mod-funcs.txt"
        functions_of < "$SCRATCH/feed-postinst.txt" > "$SCRATCH/feed-funcs.txt"

        n_mod_a=$(wc -l < "$SCRATCH/mod-actions.txt" | tr -d ' ')
        n_feed_a=$(wc -l < "$SCRATCH/feed-actions.txt" | tr -d ' ')
        echo "--- postinst actions: module $n_mod_a, feed $n_feed_a"
        sed 's/^/      module: /' "$SCRATCH/mod-actions.txt"
        sed 's/^/      feed  : /' "$SCRATCH/feed-actions.txt"

        if [ "$n_mod_a" = 0 ]; then
            fail "Gate I: the module postinst carries no service actions -- the comparison has lost its target"
        else
            # I.a ordered coverage: the module's sequence must appear, in order,
            # in the feed's. Missing OR reordered both fail.
            python3 - "$SCRATCH/mod-actions.txt" "$SCRATCH/feed-actions.txt" <<'PY' > "$SCRATCH/seq.txt" 2>&1
import sys
mod = [l.strip() for l in open(sys.argv[1]) if l.strip()]
feed = [l.strip() for l in open(sys.argv[2]) if l.strip()]
i = 0
for act in mod:
    while i < len(feed) and feed[i] != act:
        i += 1
    if i == len(feed):
        print("%s" % act)
        sys.exit(1)
    i += 1
sys.exit(0)
PY
            if [ $? -eq 0 ]; then
                ok "Gate I: the module's $n_mod_a service action(s) are all present in the feed postinst, in the module's order"
            else
                fail "Gate I: the feed postinst does not perform the module's postinst sequence -- first missing/reordered action: $(cat "$SCRATCH/seq.txt")"
            fi
        fi

        # I.b helper parity: whatever the module's body defines and calls, the
        # feed's copy must define too.
        while read -r fn; do
            [ -n "$fn" ] || continue
            grep -qx "$fn" "$SCRATCH/feed-funcs.txt" || \
                fail "Gate I: the module postinst defines '$fn' but the feed postinst does not"
        done < "$SCRATCH/mod-funcs.txt"

        # I.c the guard, named. These two lines are the fix for the measured
        # bench defect, so they are asserted by name, not only by sequence.
        ln_last_uci=$(grep -n '/etc/uci-defaults/' "$SCRATCH/feed-postinst.txt" | tail -n 1 | cut -d: -f1)
        ln_fw=$(grep -n '/etc/init\.d/firewall[[:space:]]\+reload' "$SCRATCH/feed-postinst.txt" | head -n 1 | cut -d: -f1)
        ln_nd=$(grep -n '/etc/init\.d/nodogsplash[[:space:]]\+restart' "$SCRATCH/feed-postinst.txt" | head -n 1 | cut -d: -f1)

        if [ -z "$ln_fw" ]; then
            fail "Gate I: the feed postinst never reloads the firewall -- the nftables fragments ship but stay INERT until a reboot (the published pre17 defect: :8090/:8443 answered 200 from br-lan)"
        elif [ -z "$ln_nd" ]; then
            fail "Gate I: the feed postinst never restarts nodogsplash -- an fw4 reload flushes ND's injected chains, so the captive redirect stays incomplete"
        else
            if [ -n "$ln_last_uci" ] && [ "$ln_fw" -lt "$ln_last_uci" ]; then
                fail "Gate I: the firewall reload (line $ln_fw) precedes the last uci-defaults invocation (line $ln_last_uci) -- the config would be reloaded BEFORE it is written"
            else
                ok "Gate I: firewall reload follows the last uci-defaults invocation (defaults line $ln_last_uci, reload line $ln_fw)"
            fi
            if [ "$ln_nd" -lt "$ln_fw" ]; then
                fail "Gate I: the nodogsplash restart (line $ln_nd) precedes the firewall reload (line $ln_fw) -- the fw4 reload would flush ND's freshly injected chains"
            else
                ok "Gate I: nodogsplash restart follows the firewall reload (reload line $ln_fw, ND restart line $ln_nd)"
            fi
        fi
    fi
fi

# ---------------------------------------------------------------- Gate J ----
# PAIR GATE: uhttpd.main.redirect_https has TWO writers and must have ONE rule.
#
# 92-tollgate-admin-setup (vendored here from the portal pin) and the pinned
# module tarball's 99-tollgate-setup both write uhttpd.main.redirect_https, and
# which one lands last depends on the install path -- the module's postinst runs
# the uci-defaults as 90, 99, 92, while boot runs them numerically as 90, 92, 99.
# Two scripts writing one DERIVED value are only safe while they evaluate the
# same rule; the pre17 bench defect is what happens when they do not (the board's
# :8443 carried the image's placeholder certificate and :8090 redirected to it --
# a hard certificate error on every admin login). See the header.
#
# Gate J.c accepts TWO guard shapes, because this gate recognises a guard by WHAT
# the script does, not by how it is spelled. Either the arming condition names the
# predicate (`if [ -n "$cert" ] && cert_covers_router "$cert"; then`), or it tests
# a flag that ONLY the predicate can arm:
#       local ... covers="0"                        # default FALSE
#       if cert_covers_router "$candidate_cert"; then ... covers="1" ...
#       if [ "$covers" = "1" ]; then ... redirect_https='1' ...
# The second shape is the module's #612 refactor (measured 2026-10-06 against the
# cec22228 pin): the derived hop is decided once, before the uhttpd listeners are
# written, so the arming line no longer repeats the predicate call. Accepting it is
# not a weakening: the flag counts as guarded only when it defaults false, EVERY
# truthy assignment to it sits under a condition naming the predicate, and nothing
# else assigns it -- and gate_jc_control proves on every run that a flag the
# predicate does not gate is still reported as unguarded.
GATE_J_92="$FEED/files/uci-defaults/92-tollgate-admin-setup"
GATE_J_99=""
if [ -n "$TOP" ]; then
    GATE_J_99="$TOP/packaging/files/etc/uci-defaults/99-tollgate-setup"
fi

# Non-comment lines only, the same convention as Gates H and I: a commented-out
# assignment is documentation, never an execution.
code_only() { awk '/^[[:space:]]*#/ { next } { print }' "$1"; }

# "<cli> ssl covers", normalised (quotes/braces/space removed), one line per
# invocation on a non-comment line -- the shared-predicate fingerprint.
predicate_fingerprint() {
    awk '
        /^[[:space:]]*#/ { next }
        match($0, /[^[:space:]]+[[:space:]]+ssl[[:space:]]+covers/) {
            s = substr($0, RSTART, RLENGTH)
            gsub(/[[:space:]"$\{\}]/, "", s)
            print s
        }
    ' "$1" | LC_ALL=C sort -u
}

# Names of the shell functions whose body invokes the predicate. Gate J.c uses
# them as the "armed by coverage" marker, so a guard is recognised by WHAT the
# script does (call the predicate), not by a hard-coded function name.
predicate_funcs() {
    awk '
        /^[[:space:]]*#/ { next }
        match($0, /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) {
            fn = substr($0, RSTART, RLENGTH)
            gsub(/[[:space:]()]/, "", fn)
            next
        }
        /ssl[[:space:]]+covers/ { if (fn != "") print fn }
    ' "$1" | LC_ALL=C sort -u | tr '\n' ' '
}

# Every redirect_https='1' assignment whose guarding condition neither names the
# predicate nor tests a flag that only the predicate can arm. The condition is
# read from the nearest preceding if/elif line through its "then", so a
# multi-line condition counts in full. Both accepted shapes are described above.
unguarded_arms() {   # $1=file $2=space-separated predicate function names
    awk -v q="'" -v qc="[\"']" -v preds="$2" '
        BEGIN {
            n = split(preds, p, " ")
            for (i = 1; i <= n; i++) if (p[i] != "") want[p[i]] = 1
        }
        # Does this condition text name the predicate, directly or by calling a
        # function whose body invokes it?
        function names_pred(c,   nm) {
            if (c ~ /ssl[[:space:]]+covers/) return 1
            for (nm in want) if (index(c, nm) > 0) return 1
            return 0
        }
        # The variables a condition tests with `= "1"` / `= 1`, space-separated:
        # the hoisted shape (module #612) arms the hop from a flag, not a call.
        function tested_vars(c,   s, out) {
            out = ""
            while (match(c, /\$"?[A-Za-z_][A-Za-z0-9_]*"?[[:space:]]*=[[:space:]]*"?1"?/)) {
                s = substr(c, RSTART, RLENGTH)
                c = substr(c, RSTART + RLENGTH)
                gsub(/[\$"[:space:]]/, "", s)
                sub(/=1$/, "", s)
                if (s != "") out = out " " s
            }
            return out
        }
        { L[NR] = $0 }
        END {
            fn = 0; incond = 0; cond = ""; k = 0
            for (i = 1; i <= NR; i++) {
                line = L[i]
                if (line ~ /^[[:space:]]*#/) continue
                if (line ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/) { fn++; incond = 0; cond = ""; continue }
                if (line ~ /^[[:space:]]*(if|elif)[[:space:]]/) { incond = 1; cond = "" }
                if (incond) {
                    cond = cond " " line
                    if (line ~ /;[[:space:]]*then[[:space:]]*$/ || line ~ /^[[:space:]]*then[[:space:]]*$/) incond = 0
                }
                # Classify every assignment on the line by its value: false
                # default (0/""), truthy (1/true), or anything else (a flag that
                # carries a value the predicate does not decide).
                m = split(line, tok, /[[:space:];]+/)
                for (j = 1; j <= m; j++) {
                    if (tok[j] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
                    eq = index(tok[j], "=")
                    vname = substr(tok[j], 1, eq - 1)
                    vval = substr(tok[j], eq + 1)
                    # Normalise the literal first: "0", '0' and 0 are one value,
                    # and the same for the truthy spellings. Without this a quoted
                    # default is read as a value the predicate does not decide.
                    v = vval
                    gsub("^" qc, "", v)
                    gsub(qc "$", "", v)
                    key = fn SUBSEP vname
                    if (v == "" || v == "0" || v == "false" || v == "no") {
                        if (!(key in vfalse)) vfalse[key] = i
                    } else if (v == "1" || v == "true" || v == "yes") {
                        vtrue[key]++
                        if (names_pred(cond) == 0) vbad[key]++
                        if (!(key in vfirst)) vfirst[key] = i
                    } else {
                        vother[key] = 1
                    }
                }
                if (index(line, "redirect_https=" q "1" q) > 0) {
                    k++
                    armline[k] = i; armtext[k] = line; armcond[k] = cond; armfn[k] = fn
                    incond = 0
                }
            }
            for (k2 = 1; k2 <= k; k2++) {
                hit = names_pred(armcond[k2])
                if (hit == 0) {
                    nv = split(tested_vars(armcond[k2]), vv, " ")
                    for (j = 1; j <= nv; j++) {
                        key = armfn[k2] SUBSEP vv[j]
                        # Guarded only if: the flag has a false default, the
                        # predicate is the sole setter of every truthy value, and
                        # nothing else assigns it.
                        if ((key in vfalse) && (key in vtrue) && !(key in vbad) && !(key in vother) && vfalse[key] < vfirst[key]) hit = 1
                    }
                }
                if (hit == 0) printf "%d: %s\n", armline[k2], armtext[k2]
            }
        }
    ' "$1"
}

# Gate J.c's own control. The extension above accepts a second guard shape, so it
# must be shown to still REJECT a flag the predicate does not gate -- otherwise an
# "extension" that accepts everything would pass invisibly. Two synthetic writers,
# one per shape: the first is the module's #612 refactor, the second initialises
# the flag true and arms it from a test the predicate never decides.
gate_jc_control() {
    gjc_ok="$SCRATCH/jc-control-hoisted.sh"
    gjc_bad="$SCRATCH/jc-control-ungated.sh"
    cat > "$gjc_ok" <<'JC_OK'
setup_uhttpd_tls_identity() {
    local cert="" key="" covers="0"
    if cert_covers_router "$cert"; then
        cert="$cert"
        covers="1"
    fi
    if [ "$covers" = "1" ]; then
        uci set uhttpd.main.redirect_https='1'
    else
        uci set uhttpd.main.redirect_https='0'
    fi
}
JC_OK
    cat > "$gjc_bad" <<'JC_BAD'
setup_uhttpd_tls_identity() {
    local cert="" key="" covers="1"
    if [ -n "$cert" ]; then
        covers="1"
    fi
    if [ "$covers" = "1" ]; then
        uci set uhttpd.main.redirect_https='1'
    else
        uci set uhttpd.main.redirect_https='0'
    fi
}
JC_BAD
    gjc_hit_ok=$(unguarded_arms "$gjc_ok" "cert_covers_router" | wc -l | tr -d ' ')
    gjc_hit_bad=$(unguarded_arms "$gjc_bad" "cert_covers_router" | wc -l | tr -d ' ')
    if [ "$gjc_hit_ok" = "0" ] && [ "$gjc_hit_bad" != "0" ]; then
        ok "Gate J.c control: the hoisted guard is accepted (0 site(s)) and an ungated flag is still rejected ($gjc_hit_bad site(s))"
    else
        fail "Gate J.c control: the detection does not discriminate -- hoisted guard reported $gjc_hit_ok unguarded site(s) (want 0), ungated flag reported $gjc_hit_bad (want >=1). A predicate check that cannot fail is not a check."
    fi
}

gate_j_one() {   # $1=file $2=label $3=where to write the fingerprint
    gj_f="$1"
    gj_label="$2"

    if [ ! -f "$gj_f" ]; then
        fail "Gate J: $gj_label not found ($gj_f) -- the pair cannot be compared"
        : > "$3"
        return 0
    fi

    # J.a -- evaluates the SHARED coverage predicate, through the module CLI.
    # Whether it is the SAME predicate as the other writer's is settled by J.d.
    predicate_fingerprint "$gj_f" > "$3"
    if [ ! -s "$3" ]; then
        fail "Gate J.a: $gj_label never invokes the coverage predicate ('ssl covers' on the module CLI) -- its redirect_https is derived on a premise of its own, which is the pre17 placeholder-certificate defect"
    else
        ok "Gate J.a: $gj_label derives the redirect from the shared coverage predicate: $(tr '\n' ',' < "$3" | sed 's/,$//')"
    fi

    # J.b -- an explicit value in BOTH directions, so whichever writer lands last
    # cannot leave the other's stale value in place.
    gj_one=$(code_only "$gj_f" | grep -c "uhttpd.main.redirect_https='1'")
    gj_zero=$(code_only "$gj_f" | grep -c "uhttpd.main.redirect_https='0'")
    if [ "$gj_one" -gt 0 ] && [ "$gj_zero" -gt 0 ]; then
        ok "Gate J.b: $gj_label writes uhttpd.main.redirect_https explicitly both ways ('1' x$gj_one, '0' x$gj_zero)"
    else
        fail "Gate J.b: $gj_label does not write uhttpd.main.redirect_https explicitly both ways ('1' x$gj_one, '0' x$gj_zero) -- an install order could leave a stale value behind"
    fi

    # J.c -- every arming write is guarded by the predicate.
    gj_preds=$(predicate_funcs "$gj_f")
    unguarded_arms "$gj_f" "$gj_preds" > "$SCRATCH/j-unguarded.txt"
    if [ -s "$SCRATCH/j-unguarded.txt" ]; then
        gj_n=$(wc -l < "$SCRATCH/j-unguarded.txt" | tr -d ' ')
        fail "Gate J.c: $gj_label arms a redirect_https hop from a condition that neither names the coverage predicate nor tests a flag only the predicate can arm ($gj_n site(s)); predicate markers found: '${gj_preds:-none}'"
        sed 's/^/      UNGUARDED: /' "$SCRATCH/j-unguarded.txt" >&2
    else
        ok "Gate J.c: every redirect_https='1' in $gj_label is armed by the coverage predicate"
    fi
}

gate_jc_control
gate_j_one "$GATE_J_92" "the vendored 92 (files/uci-defaults/92-tollgate-admin-setup)" "$SCRATCH/j-fp-92.txt"
gate_j_one "$GATE_J_99" "the pinned tarball's 99-tollgate-setup (packaging/files/etc/uci-defaults/)" "$SCRATCH/j-fp-99.txt"

# J.d -- the two writers must evaluate the SAME predicate, not merely both have
# one: a fingerprint mismatch means one derived value is decided by two different
# rules, which is the defect the pair gate exists for.
if [ -s "$SCRATCH/j-fp-92.txt" ] && [ -s "$SCRATCH/j-fp-99.txt" ]; then
    fj_92=$(cat "$SCRATCH/j-fp-92.txt")
    fj_99=$(cat "$SCRATCH/j-fp-99.txt")
    if [ "$fj_92" = "$fj_99" ]; then
        ok "Gate J.d: both writers call the same predicate ($(printf '%s' "$fj_92" | tr '\n' ',' | sed 's/,$//'))"
    else
        fail "Gate J.d: the two writers evaluate DIFFERENT coverage predicates"
        echo "      vendored 92 : $(printf '%s' "$fj_92" | tr '\n' ',')" >&2
        echo "      tarball 99  : $(printf '%s' "$fj_99" | tr '\n' ',')" >&2
    fi
fi

if [ "$FAIL" = 1 ]; then
    echo "test-pkg-tarball-parity: FAILED" >&2
    exit 1
fi
echo "test-pkg-tarball-parity: PASS"
exit 0
