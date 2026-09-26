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

if [ "$FAIL" = 1 ]; then
    echo "test-pkg-tarball-parity: FAILED" >&2
    exit 1
fi
echo "test-pkg-tarball-parity: PASS"
exit 0
