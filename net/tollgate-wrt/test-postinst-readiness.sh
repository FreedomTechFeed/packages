#!/bin/sh
# test-postinst-readiness.sh -- the postinst must not declare an install "done"
# while the money path is still blind.
#
# WHY THIS EXISTS (measured on the bench MT3000, 2026-09-25, pre17 after a fresh
# install + reboot): the portal half of the box was perfect and the commercial
# half was dead. /etc/init.d/tollgate-wrt status printed "running", :2121 was
# absent from the listening sockets, /var/run/tollgate.sock did not exist, and
# `tollgate wallet balance` failed with "dial unix /var/run/tollgate.sock:
# connect: no such file or directory". The same operator re-ran minutes later
# WITHOUT changing anything and got "PASS TCP 2121".
#
# That is not a crash: tollgate-wrt does its startup mint probe BEFORE it binds,
# so the process can be alive (procd: running) for minutes while :2121 is not
# there. Neither pre17 nor pre18's postinst waited for the API, so an install
# could report success — and the club's acceptance run then refused at stage 0
# with "TCP 2121 not answering", which is the correct call against a dead API.
#
# The postinst now has a bounded readiness gate. This test holds it in place
# without hardware, the same way the rest of this directory's tests do:
#
#   Gate A  the shipped postinst body contains a bounded wait for :2121
#           (RED on the pre17/pre18 body, which had none)
#   Gate B  the body under test IS the shipped body: the fakeroot path rewrite
#           used to run it is reversible and reverses to the extracted text
#   Gate C  when the API is already up the gate costs ONE probe and no sleep —
#           the normal install pays nothing
#   Gate D  when the API comes up late the gate reports the wait it actually did
#   Gate E  when the API never comes up the gate is BOUNDED (48 probes at 5 s),
#           says so loudly with the diagnostics, and still exits 0 — a correct
#           install is never rolled back for a slow mint probe
#
# Exit status: 0 = pass, 1 = fail. Needs awk, sed, sh, mktemp, grep, diff.
# No network, no router, no root.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MK="$REPO_ROOT/net/tollgate-wrt/Makefile"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

FAIL=0
ok() { echo "OK: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

[ -f "$MK" ] || { echo "FAIL: $MK not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Extract the postinst body and un-escape it the way the package build does.
# Inside a define, "$$" is the shell's "$" (the install recipe is expanded more
# than once, the postinst body once — the existing "$$script" / "$$?" / "$$(...)"
# in this very body are the shipped proof of that).
# ---------------------------------------------------------------------------
BODY="$SCRATCH/postinst.sh"
awk '/^define Package\/tollgate-wrt\/postinst$/ { inpo = 1; next }
     inpo && /^endef$/ { exit }
     inpo { print }' "$MK" | sed 's/\$\$/$/g' > "$BODY"

if [ ! -s "$BODY" ]; then
	fail "Gate A: no postinst body extracted from $MK"
	echo "test-postinst-readiness: FAILED" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Gate A -- structure: a bounded wait for :2121 exists at all.
# ---------------------------------------------------------------------------
grep -q 'tollgate_api_listening' "$BODY" \
	|| fail "Gate A: the postinst has no API-readiness probe (pre17/pre18 shape: install declared done with :2121 blind)"
grep -q ':2121' "$BODY" \
	|| fail "Gate A: the readiness probe does not test :2121"
grep -Eq 'while \[ .*tollgate_ready_waited.* -lt [0-9]+ \]' "$BODY" \
	|| fail "Gate A: the readiness wait is not a bounded loop (an unbounded wait in a postinst is a hang)"
if [ "$FAIL" = 0 ]; then
	ok "Gate A: the postinst waits for :2121 in a bounded loop"
fi

# ---------------------------------------------------------------------------
# Fakeroot. The postinst addresses absolute paths (/etc, /sys, /usr), so we
# rewrite those PREFIXES into a throw-away root. Nothing else is rewritten, and
# Gate B proves it.
# ---------------------------------------------------------------------------
FAKE="$SCRATCH/root"
mkdir -p "$FAKE/etc/uci-defaults" "$FAKE/etc/init.d" "$FAKE/sys/class/net/br-lan" \
	"$FAKE/sys/class/net/br-private" \
	"$FAKE/usr/bin" "$FAKE/bin" "$FAKE/shim" "$FAKE/state"
for s in 90-tollgate-captive-portal-symlink 99-tollgate-setup 92-tollgate-admin-setup; do
	printf '#!/bin/sh\necho "ran:%s"\n' "$s" > "$FAKE/etc/uci-defaults/$s"
	chmod +x "$FAKE/etc/uci-defaults/$s"
done
printf '#!/bin/sh\necho "initd:$(basename "$0") $*"\n' > "$FAKE/etc/init.d/tollgate-wrt"
chmod +x "$FAKE/etc/init.d/tollgate-wrt"
for s in network; do
	printf '#!/bin/sh\necho "initd:%s $*"\n' "$s" > "$FAKE/etc/init.d/$s"
	chmod +x "$FAKE/etc/init.d/$s"
done
printf '#!/bin/sh\necho "wifi $*"\n' > "$FAKE/shim/wifi"
chmod +x "$FAKE/shim/wifi"

REWRITTEN="$SCRATCH/postinst.fakeroot.sh"
sed -e "s#/etc/#$FAKE/etc/#g" \
    -e "s#/sys/#$FAKE/sys/#g" \
    -e "s#/usr/#$FAKE/usr/#g" \
    "$BODY" > "$REWRITTEN"

# Gate B: the rewrite is exactly those three prefixes, i.e. reversible.
sed -e "s#$FAKE/etc/#/etc/#g" \
    -e "s#$FAKE/sys/#/sys/#g" \
    -e "s#$FAKE/usr/#/usr/#g" \
    "$REWRITTEN" > "$SCRATCH/reversed.sh"
if diff -u "$BODY" "$SCRATCH/reversed.sh" > "$SCRATCH/reverse.diff" 2>&1; then
	ok "Gate B: the fakeroot rewrite is prefix-only, so the body under test is the shipped body"
else
	fail "Gate B: the fakeroot rewrite is not reversible — the body under test is NOT the shipped body"
	sed 's/^/      /' "$SCRATCH/reverse.diff" >&2
fi

# ---------------------------------------------------------------------------
# PATH doubles. Only what the gate needs: netstat (the readiness signal), sleep
# (so the bounded wait is instant), and a no-op for the stray `wifi` call.
# ---------------------------------------------------------------------------
cat > "$FAKE/shim/netstat" <<'SHIM'
#!/bin/sh
# Prints the :2121 LISTEN line once the scripted "ready_at"-th call is reached.
c=0
[ -f "$TG_SHIM_STATE/probe_calls" ] && c=$(cat "$TG_SHIM_STATE/probe_calls")
c=$((c + 1))
echo "$c" > "$TG_SHIM_STATE/probe_calls"
ready_at=1
[ -f "$TG_SHIM_STATE/ready_at" ] && ready_at=$(cat "$TG_SHIM_STATE/ready_at")
if [ "$c" -ge "$ready_at" ]; then
	echo "tcp        0      0 0.0.0.0:2121            0.0.0.0:*               LISTEN"
fi
exit 0
SHIM
chmod +x "$FAKE/shim/netstat"

cat > "$FAKE/shim/sleep" <<'SHIM'
#!/bin/sh
c=0
[ -f "$TG_SHIM_STATE/sleep_calls" ] && c=$(cat "$TG_SHIM_STATE/sleep_calls")
echo "$((c + 1))" > "$TG_SHIM_STATE/sleep_calls"
exit 0
SHIM
chmod +x "$FAKE/shim/sleep"

run_postinst() {
	rm -f "$FAKE/state/probe_calls" "$FAKE/state/sleep_calls"
	echo "$1" > "$FAKE/state/ready_at"
	TG_SHIM_STATE="$FAKE/state" \
		PATH="$FAKE/shim:/usr/bin:/bin" \
		sh "$REWRITTEN" 2> "$SCRATCH/run.stderr"
}

probes() { cat "$FAKE/state/probe_calls" 2>/dev/null || echo 0; }
sleeps() { cat "$FAKE/state/sleep_calls" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# Gate C -- API already up: the loop probes once and breaks, no sleep, and the
# report runs the probe once more (2 probes total); the normal install pays
# nothing.
# ---------------------------------------------------------------------------
out=$(run_postinst 1); rc=$?
if [ "$rc" != 0 ]; then
	fail "Gate C: the postinst exited $rc with the API up"
else
	[ "$(sleeps)" = 0 ] \
		|| fail "Gate C: the postinst slept $(sleeps)x even though the API answered immediately — every install would pay the wait"
	[ "$(probes)" = 2 ] \
		|| fail "Gate C: expected 2 probes (1 in the loop + 1 in the report), saw $(probes)"
	[ "$(sleeps)" = 0 ] && [ "$(probes)" = 2 ] && ok "Gate C: API up -> 2 probes, 0 sleeps (the install pays nothing)"
fi
echo "$out" | grep -q 'API answering on :2121 after 0s' \
	&& ok "Gate C: reports the API as answering" \
	|| fail "Gate C: no 'API answering on :2121' line in the postinst output"

# ---------------------------------------------------------------------------
# Gate D -- API comes up late (3rd probe): 2 failed probes, 2 sleeps, then the
# report probe; the wait it actually took is printed.
# ---------------------------------------------------------------------------
out=$(run_postinst 3)
echo "$out" | grep -q 'API answering on :2121 after 10s' \
	&& ok "Gate D: a late API is reported with the wait it actually took (10s = 2 x 5s sleeps)" \
	|| fail "Gate D: expected 'API answering on :2121 after 10s'"
[ "$(sleeps)" = 2 ] \
	&& ok "Gate D: slept exactly twice before the API answered" \
	|| fail "Gate D: expected 2 sleeps, saw $(sleeps)"
[ "$(probes)" = 4 ] \
	&& ok "Gate D: 4 probes (3 attempts + the report)" \
	|| fail "Gate D: expected 4 probes, saw $(probes)"

# ---------------------------------------------------------------------------
# Gate E -- API never comes up: bounded, loud, and non-fatal.
# ---------------------------------------------------------------------------
out=$(run_postinst 999999); rc=$?
err=$(cat "$SCRATCH/run.stderr")
if [ "$rc" != 0 ]; then
	fail "Gate E: the postinst exited $rc when the API never answered — a correct install must never be rolled back for a slow mint probe"
else
	ok "Gate E: a never-ready API still exits 0 (install is not rolled back)"
fi
[ "$(probes)" = 49 ] \
	&& ok "Gate E: the wait is bounded — 49 probes (one per attempt, 48 x 5 s)" \
	|| fail "Gate E: expected 49 probes (bounded at 240 s / 5 s), saw $(probes)"
[ "$(sleeps)" = 48 ] \
	&& ok "Gate E: slept 48 times, i.e. the 240 s bound, then stopped" \
	|| fail "Gate E: expected 48 sleeps, saw $(sleeps)"
echo "$out$err" | grep -q 'has not bound :2121 after 240s' \
	&& ok "Gate E: says loudly that the money path is not serving" \
	|| fail "Gate E: no 'has not bound :2121 after 240s' warning"
echo "$out$err" | grep -q 'RunInitialProbe' \
	&& ok "Gate E: names the diagnostic that separates 'still probing' from 'crashed'" \
	|| fail "Gate E: the warning does not point at RunInitialProbe in logread"
echo "$out$err" | grep -q 'tollgate.sock' \
	&& ok "Gate E: names the CLI socket, the other thing that is missing in that window" \
	|| fail "Gate E: the warning does not mention /var/run/tollgate.sock"

if [ "$FAIL" = 1 ]; then
	echo "test-postinst-readiness: FAILED" >&2
	exit 1
fi
echo "test-postinst-readiness: PASS"
exit 0
