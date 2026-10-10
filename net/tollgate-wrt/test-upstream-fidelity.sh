#!/bin/sh
# test-upstream-fidelity.sh -- Gate L: the package ships ONLY bytes upstream can accept.
#
# WHY THIS EXISTS
#   The operator's question that produced it: "docker registries get us fast builds,
#   but we can't merge our packages to upstream openwrt if we use them -- do we need a
#   fast fork AND a slow, pristine fork?"
#
#   Answer: no. Two facts make one tree sufficient.
#     (1) Upstream's own build IS a container registry: openwrt/packages'
#         multi-arch-test-build.yml is a stub delegating to
#         openwrt/actions-shared-workflows, which uses openwrt/gh-action-sdk.
#     (2) An upstream PR is PER-PATH: the maintainer reviews the package directory
#         (net/<pkg>/), and .github/** is never part of a package submission.
#   So fork-local speed machinery and an upstream-mergeable package coexist -- but ONLY
#   if the split between "travels upstream" and "fork-local forever" is EXPLICIT and
#   ENFORCED. This gate is that enforcement. Without it the split is a convention that
#   silently rots (a new CI helper dropped into the package dir, a stray workflow, a
#   fork URL in a Makefile comment) and the first symptom is a rejected upstream PR.
#
# WHAT IT ASSERTS
#   L1  net/tollgate-wrt/UPSTREAM-MANIFEST.txt exists and is well-formed; every glob in
#       it matches at least one tracked file (no stale entries).
#   L2  EVERY tracked file under net/tollgate-wrt/ is classified EXACTLY ONCE. A newly
#       added file fails this gate until someone classifies it. That is the point:
#       classification is a decision, never a default.
#   L3  Nothing under net/tollgate-wrt/files/ is classified fork-local. files/ is both
#       the payload installed on the router and the artifact upstream reviews.
#   L4  net/tollgate-wrt/Makefile is classified upstream -- it is the core artifact, and
#       the thing a package PR is actually about.
#
# Exit status: 0 = pass, 1 = fail.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PKG_REL="net/tollgate-wrt"
MANIFEST="$ROOT/$PKG_REL/UPSTREAM-MANIFEST.txt"
FAIL=0

fail() {
    echo "FAIL: $1" >&2
    FAIL=1
}

ok() {
    echo "OK: $1"
}

if ! command -v git >/dev/null 2>&1 || ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    fail "Gate L: this gate needs a git checkout (it reads the tracked file list); no git repository at $ROOT"
    echo "test-upstream-fidelity: FAILED" >&2
    exit 1
fi

# --- L1: the manifest exists and is well-formed ----------------------------
if [ ! -f "$MANIFEST" ]; then
    fail "Gate L: $PKG_REL/UPSTREAM-MANIFEST.txt is missing. Without it there is NO enforced split between what travels to upstream openwrt/packages and what stays fork-local, so 'package bytes only' is a hope rather than a rule"
    echo "test-upstream-fidelity: FAILED" >&2
    exit 1
fi

ENTRIES=$(mktemp) || exit 1
TRACKED=$(mktemp) || exit 1
N_UP=0
N_FORK=0

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '' | '#'*) continue ;;
    esac
    # split on runs of spaces/tabs: <classification> <glob>
    cls=$(printf '%s' "$line" | awk '{print $1}')
    glob=$(printf '%s' "$line" | awk '{print $2}')
    if [ -z "$glob" ]; then
        fail "Gate L: manifest line has a classification but no path/glob: $line"
        continue
    fi
    case "$cls" in
        upstream)
            N_UP=$((N_UP + 1))
            ;;
        fork-local)
            N_FORK=$((N_FORK + 1))
            ;;
        *)
            fail "Gate L: manifest line uses an unknown classification '$cls' (only 'upstream' and 'fork-local' exist): $line"
            continue
            ;;
    esac
    printf '%s|%s\n' "$cls" "$glob" >>"$ENTRIES"
done <"$MANIFEST"

if [ "$N_UP" -eq 0 ] || [ "$N_FORK" -eq 0 ]; then
    fail "Gate L: the manifest classifies nothing as upstream ($N_UP) and/or nothing as fork-local ($N_FORK); both kinds must exist or the split is not real"
fi

git -C "$ROOT" ls-files -- "$PKG_REL" >"$TRACKED"

# every manifest glob must match at least one tracked file (no stale entries)
while IFS='|' read -r cls glob; do
    hit=0
    while IFS= read -r path; do
        case "$path" in
            $glob) hit=1 ;;
        esac
    done <"$TRACKED"
    [ "$hit" = 1 ] || fail "Gate L: the manifest classifies '$glob' as $cls but no tracked file matches it (stale entry -- the path was deleted or renamed)"
done <"$ENTRIES"
[ "$FAIL" = 0 ] && ok "Gate L: the manifest is well-formed and every entry matches a tracked file"

# --- L2 / L3 / L4: classify every tracked file ------------------------------
UNCLASSIFIED=""
AMBIGUOUS=""
L3_BAD=""
L4_BAD=0
N_FILES=0

while IFS= read -r path; do
    N_FILES=$((N_FILES + 1))
    m=0
    mcls=""
    while IFS='|' read -r cls glob; do
        case "$path" in
            $glob)
                m=$((m + 1))
                mcls="$cls"
                ;;
        esac
    done <"$ENTRIES"
    if [ "$m" -eq 0 ]; then
        UNCLASSIFIED="$UNCLASSIFIED $path"
    elif [ "$m" -gt 1 ]; then
        AMBIGUOUS="$AMBIGUOUS $path"
    fi
    case "$path" in
        "$PKG_REL"/files/*)
            # L3: the installed payload always travels upstream
            [ "$mcls" = "fork-local" ] && L3_BAD="$L3_BAD $path"
            ;;
    esac
    if [ "$path" = "$PKG_REL/Makefile" ] && [ "$mcls" != "upstream" ]; then
        L4_BAD=1
    fi
done <"$TRACKED"

if [ -n "$UNCLASSIFIED" ]; then
    fail "Gate L: these tracked files are NOT classified in UPSTREAM-MANIFEST.txt, so whether they travel to upstream is undefined:$UNCLASSIFIED"
else
    ok "Gate L: all $N_FILES tracked files under $PKG_REL/ are classified"
fi

if [ -n "$AMBIGUOUS" ]; then
    fail "Gate L: these tracked files are classified MORE THAN ONCE (a file must travel or not travel, not both):$AMBIGUOUS"
fi

if [ -n "$L3_BAD" ]; then
    fail "Gate L: files/ is the installed payload AND the artifact upstream reviews, so it must never be classified fork-local:$L3_BAD"
else
    ok "Gate L: net/tollgate-wrt/files/ travels upstream in full"
fi

if [ "$L4_BAD" = 1 ]; then
    fail "Gate L: net/tollgate-wrt/Makefile is the core artifact a package PR is about; it must be classified upstream"
else
    ok "Gate L: the Makefile is classified upstream"
fi

rm -f "$ENTRIES" "$TRACKED"

if [ "$FAIL" = 1 ]; then
    echo "test-upstream-fidelity: FAILED" >&2
    exit 1
fi
echo "test-upstream-fidelity: PASS"
exit 0
