#!/bin/sh
# test-uci-defaults-order.sh -- pin the /etc/uci-defaults RUN ORDER: the
# credential must exist BEFORE the fail-closed admin gate, and the gate must run
# LAST.
#
# WHY THIS EXISTS (measured on the bench, pre26). /etc/uci-defaults/* are applied
# in ONE collated glob by /etc/init.d/boot, so a script's NUMERIC PREFIX IS its
# run order. Two of the three scripts matter for the admin board:
#
#   99-tollgate-setup        (module tarball) CREATES the root credential.
#   92-tollgate-admin-setup  (vendored here from the portal pin) is FAIL CLOSED:
#                            while root's /etc/shadow hash is empty it DELETES
#                            uhttpd.admin's listeners -- "the board must be
#                            UNREACHABLE, not merely unhelpful".
#
# Under the old numeric order (90, 92, 99) the gate ran BEFORE the credential
# existed, so a fresh install knocked the admin board off the air with nothing to
# restore it (the field workaround was `passwd root` before installing). The feed
# postinst already ran gate-last (90, 99, 92); the boot glob did not. The fix
# unifies BOTH on gate-last: the gate is STAGED as 999-tollgate-admin-setup (which
# sorts after 99- in the boot glob) and both the postinst loop and the boot pass
# run 90, 99, 999. The module repo's packaging does the same, so an install and
# the next boot agree on the last writer.
#
# The gate's SOURCE keeps its upstream name (files/uci-defaults/
# 92-tollgate-admin-setup): it is a verbatim vendored copy, byte-compared against
# the portal pin by .github/scripts/check-vendor-drift.sh, so only the INSTALLED
# name may move. This test pins both halves -- the source name is unchanged, the
# INSTALLED name (what the boot glob sees) is gate-last -- and judges the postinst
# loop AND the boot-glob order by ONE predicate.
#
# Exit status: 0 = pass, 1 = fail. House style of test.sh / test-devendored.sh.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FEED="$ROOT/net/tollgate-wrt"
MK="$FEED/Makefile"
FAIL=0

ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

# The credential-creating script (module-owned; installed from the module
# tarball) and the fail-closed gate's vendored SOURCE name (committed here, so
# its name is the portal's and must not change).
CRED_NAME="99-tollgate-setup"
GATE_SRC_NAME="92-tollgate-admin-setup"
GATE_SRC="$FEED/files/uci-defaults/$GATE_SRC_NAME"

# ---------------------------------------------------------------------------
# THE ONE PREDICATE. Judged identically against the postinst loop order and the
# boot-glob order, so the two orders cannot be checked by two different rules.
# stdin = ordered uci-defaults script names, one per line. Prints nothing when
# the credential precedes the gate AND the gate is last; otherwise prints why.
# ---------------------------------------------------------------------------
order_violation() {   # $1 = the gate's (installed) name
    gate="$1"
    awk -v gate="$gate" -v cred="$CRED_NAME" '
        NF { n++; name[n] = $0 }
        END {
            if (n == 0) { print "the ordered list carries no scripts"; exit }
            if (name[n] != gate) { printf "the gate (%s) is not last -- %s runs after it", gate, name[n]; exit }
            for (i = 1; i <= n; i++) {
                if (name[i] == gate) g = i
                if (name[i] == cred) c = i
            }
            if (g == 0) { printf "the ordered list carries no gate (%s)", gate; exit }
            if (c == 0) { printf "the ordered list carries no credential script (%s)", cred; exit }
            if (c > g)  { printf "the credential (%s) runs AFTER the gate (%s)", cred, gate; exit }
        }
    '
}

# The gate's INSTALLED name: the last field (the destination) of the install line
# that stages files/uci-defaults/<gate src>. Comment lines are skipped, so the
# recipe may keep documenting the name without the parser reading prose.
gate_installed_name() {
    raw=$(awk -v src="files/uci-defaults/$GATE_SRC_NAME" '
        /^[[:space:]]*#/ { next }
        index($0, src) {
            for (i = NF; i >= 1; i--) if ($i != "") { print $i; exit }
        }
    ' "$MK" | head -n 1)
    case "$raw" in
        # Destination is a DIRECTORY: install keeps the source basename.
        */) printf '%s\n' "$GATE_SRC_NAME" ;;
        # Destination names the file: its basename is the installed name.
        "") : ;;
        *)  printf '%s\n' "${raw##*/}" ;;
    esac
}

# The ordered names the postinst for-loop runs (the /etc/uci-defaults/<name>
# tokens of the `for script in ...; do` list, in order).
postinst_order() {
    awk '
        /^[[:space:]]*#/ { next }
        /for script in/ { inl = 1 }
        inl {
            n = split($0, tok, /[[:space:]]+/)
            for (i = 1; i <= n; i++)
                if (tok[i] ~ /^\/etc\/uci-defaults\//) {
                    s = tok[i]
                    sub(/^\/etc\/uci-defaults\//, "", s)
                    gsub(/[;\\]/, "", s)
                    if (s != "") print s
                }
            if ($0 ~ /;[[:space:]]*do[[:space:]]*$/) inl = 0
        }
    ' "$MK"
}

# --- Gate A: the recipe stages the gate under a gate-last (999-) name --------
# The numeric prefix IS the boot order, so the INSTALLED name is the contract the
# boot pass honours. 92 sorts BEFORE 99-tollgate-setup (the credential) and 999
# sorts after, which is the whole fix.
GATE=$(gate_installed_name)
if [ -z "$GATE" ]; then
    fail "Gate A: no install line stages files/uci-defaults/$GATE_SRC_NAME -- the admin gate is not installed at all"
elif [ "$GATE" = "$GATE_SRC_NAME" ]; then
    fail "Gate A: the gate is installed as $GATE, its un-renamed source name -- it would sort BEFORE $CRED_NAME in the boot glob and run before the credential exists"
else
    case "$GATE" in
        999-*) ok "Gate A: the gate is staged for install as $GATE (sorts after $CRED_NAME in the boot glob)" ;;
        *)     fail "Gate A: the gate is installed as '$GATE', which is not a 999- name -- a fresh flash could run it before the credential exists" ;;
    esac
fi

# The gate we just located must actually be the fail-closed one, or the checks
# below pin the order of the wrong script. House style (llm-review-rules.md):
# never `grep -q` in a test -- keep the matched marker visible in CI logs.
if [ -f "$GATE_SRC" ]; then
    FS_MARK=$(grep -n 'FAIL CLOSED' "$GATE_SRC" | head -n 1)
else
    FS_MARK=""
fi
if [ -n "$FS_MARK" ]; then
    ok "Gate A: the vendor source $GATE_SRC is the fail-closed admin gate -- marker: $FS_MARK"
else
    fail "Gate A: $GATE_SRC is missing or carries no 'FAIL CLOSED' marker -- the order below would pin the wrong script"
fi

# --- Gate B: the postinst loop runs the credential first, the gate last ------
ORDER=$(postinst_order)
if [ -z "$ORDER" ]; then
    fail "Gate B: no /etc/uci-defaults invocation found in the postinst loop"
else
    VIOL=$(printf '%s\n' "$ORDER" | order_violation "$GATE")
    if [ -z "$VIOL" ]; then
        ok "Gate B: the postinst runs the credential ($CRED_NAME) before the fail-closed gate ($GATE), gate last: $(printf '%s' "$ORDER" | tr '\n' ',')"
    else
        fail "Gate B: postinst order violates gate-last -- $VIOL"
    fi
fi

# --- Gate C: the BOOT-GLOB order is gate-last too ---------------------------
# /etc/init.d/boot applies /etc/uci-defaults/* in one collated glob, so the
# installed NAMES sorted byte-wise ARE the boot order. Judge the SAME predicate
# against that order. This is the check the pre-fix tree fails: the boot glob
# carried 92, before the credential.
BOOT_ORDER=$(printf '%s\n' "90-tollgate-captive-portal-symlink" "$CRED_NAME" "$GATE" | LC_ALL=C sort)
if [ -n "$GATE" ]; then
    VIOL=$(printf '%s\n' "$BOOT_ORDER" | order_violation "$GATE")
    if [ -z "$VIOL" ]; then
        ok "Gate C: the boot glob order is gate-last: $(printf '%s' "$BOOT_ORDER" | tr '\n' ',')"
    else
        fail "Gate C: boot order violates gate-last -- $VIOL"
    fi
fi

# --- Gate D: the vendored source keeps its upstream name --------------------
# If the gate's SOURCE were renamed, check-vendor-drift.sh (which byte-compares
# it against the portal pin by path) would break. Only the INSTALLED name moves.
if [ -f "$GATE_SRC" ]; then
    ok "Gate D: the gate's source keeps its vendored name ($GATE_SRC_NAME) -- the drift guard still resolves it"
else
    fail "Gate D: the gate's vendored source $GATE_SRC is gone -- check-vendor-drift.sh would fail"
fi

# --- Negative controls: the predicate must DISCRIMINATE ---------------------
# A green that cannot go red proves nothing, so prove the predicate rejects the
# pre-fix ordering.
CTL_BOOT=$(printf '%s\n' "90-tollgate-captive-portal-symlink" "$GATE_SRC_NAME" "$CRED_NAME" | LC_ALL=C sort)
CTL_1=$(printf '%s\n' "$CTL_BOOT" | order_violation "$GATE_SRC_NAME")
CTL_2=$(printf '%s\n' "90-tollgate-captive-portal-symlink" "999-tollgate-admin-setup" | order_violation "999-tollgate-admin-setup")
if [ -n "$CTL_1" ] && [ -n "$CTL_2" ]; then
    ok "Gate NC: the predicate rejects the pre-fix orders -- old boot glob: '$CTL_1'; missing-credential list: '$CTL_2'"
else
    fail "Gate NC: the predicate does not discriminate -- old boot glob gave '$CTL_1', missing-credential list gave '$CTL_2' (both must be non-empty). A check that cannot fail is not a check."
fi

if [ "$FAIL" = 1 ]; then
    echo "test-uci-defaults-order: FAILED" >&2
    exit 1
fi
echo "test-uci-defaults-order: PASS"
exit 0
