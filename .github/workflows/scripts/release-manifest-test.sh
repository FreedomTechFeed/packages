#!/usr/bin/env bash
#
# Self-test for release-manifest.sh / release-assets.py — the release integrity
# tooling behind audit finding C3-05.
#
# Every case below is a way a release could ship checksum-less or mis-signed;
# the suite pins that each one FAILS the release job rather than passing
# quietly. Run locally:  bash .github/workflows/scripts/release-manifest-test.sh
#
# ---------------------------------------------------------------------------
# Evidence (both runs executed 2026-09-23 on the PR branch; the RED run points
# the suite at a copy of the generator with the C3-05 guards removed — no
# expected-set check, no empty-asset check, signing optional — to show the
# suite actually fails without them):
#
# RED   $ bash release-manifest-test.sh   # generator without the guards
#   ok   complete asset set produces a manifest
#   ok   manifest covers all 14 assets
#   ok   manifest verifies against the staged bytes
#   FAIL unsigned-manifest: expected the job to fail, it succeeded
#   ok   signed manifest is produced
#   ok   signature verifies against the pinned public key
#   ok   a different key is rejected (the pin is load-bearing)
#   FAIL missing-asset: expected the job to fail, it succeeded
#   FAIL unmanaged-asset: expected the job to fail, it succeeded
#   FAIL empty-asset: expected the job to fail, it succeeded
#   ok   bytes changed after hashing fail sha256sum --check
#   ok   the signature still verifies (it authenticates the manifest, and the hash check catches the bytes)
#   ok   legacy mode covers every file present, with no expected-set file
#   9 passed, 4 failed        <- rc=1
#
# GREEN $ bash .github/workflows/scripts/release-manifest-test.sh
#   13 passed, 0 failed       <- rc=0
# ---------------------------------------------------------------------------

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_SH="$HERE/release-manifest.sh"
ASSETS_PY="$HERE/release-assets.py"
VERSION="0.6.0_alpha4_pre15"
PASS=0
FAIL=0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { echo "ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------- fixtures
python3 "$ASSETS_PY" expected "$VERSION" > "$WORK/expected.txt"
EXPECTED_COUNT=$(grep -c . "$WORK/expected.txt")

stage() { # stage <dir> [--drop NAME] [--tamper NAME] [--empty NAME]
  local dir="$1"; shift
  rm -rf "$dir"; mkdir -p "$dir"
  # Deterministic pseudo-content: the digest values do not matter, only that
  # they change with the bytes.
  while read -r name; do
    printf 'asset %s\n' "$name" > "$dir/$name"
  done < "$WORK/expected.txt"
  while [ $# -gt 0 ]; do
    case "$1" in
      --drop)   rm -f "$dir/$2"; shift 2 ;;
      --tamper) printf 'x' >> "$dir/$2"; shift 2 ;;
      --empty)  : > "$dir/$2"; shift 2 ;;
      *) echo "bad arg $1" >&2; exit 2 ;;
    esac
  done
}

# Ephemeral signing key: the suite must not depend on the real release key.
KEY="$WORK/test-key"
ssh-keygen -q -t ed25519 -N '' -C 'test-release-signing' -f "$KEY"
OTHER_KEY="$WORK/other-key"
ssh-keygen -q -t ed25519 -N '' -C 'other-release-signing' -f "$OTHER_KEY"
KEYBODY="$(cat "$KEY")"
OTHERBODY="$(cat "$OTHER_KEY")"
FIRST_ASSET="$(head -n1 "$WORK/expected.txt")"

run() { # run <asset-dir> [expected-file] ; env: FEED_SIGNING_KEY / ALLOW_UNSIGNED
  FEED_SIGNING_KEY="${FEED_SIGNING_KEY-}" ALLOW_UNSIGNED="${ALLOW_UNSIGNED-}" \
    bash "$MANIFEST_SH" "$@" >"$WORK/out.log" 2>&1
}

# ------------------------------------------------------------- happy path
stage "$WORK/good"
if FEED_SIGNING_KEY="$KEYBODY" run "$WORK/good" "$WORK/expected.txt"; then
  pass "complete asset set produces a manifest"
else
  fail "complete asset set: $(tail -n2 "$WORK/out.log")"
fi
lines=$(grep -c . "$WORK/good/SHA256SUMS" || true)
if [ "$lines" = "$EXPECTED_COUNT" ]; then
  pass "manifest covers all $EXPECTED_COUNT assets"
else
  fail "manifest has $lines entries, want $EXPECTED_COUNT"
fi
if (cd "$WORK/good" && sha256sum --check --strict SHA256SUMS >/dev/null); then
  pass "manifest verifies against the staged bytes"
else
  fail "manifest does not verify against the staged bytes"
fi

# ---------------------------------------------------------------- no key
stage "$WORK/nokey"
if run "$WORK/nokey" "$WORK/expected.txt"; then
  fail "unsigned-manifest: expected the job to fail, it succeeded"
else
  grep -q 'FEED_SIGNING_KEY' "$WORK/out.log" \
    && pass "missing signing key refuses to publish an unsigned manifest" \
    || fail "unsigned-manifest failed for the wrong reason: $(tail -n1 "$WORK/out.log")"
fi

# -------------------------------------------------------- signed happy path
stage "$WORK/signed"
if FEED_SIGNING_KEY="$KEYBODY" run "$WORK/signed" "$WORK/expected.txt"; then
  pass "signed manifest is produced"
else
  fail "signed manifest: $(tail -n2 "$WORK/out.log")"
fi
printf 'test-release-signing %s\n' "$(cat "$KEY.pub")" > "$WORK/allowed"
if (cd "$WORK/signed" && ssh-keygen -Y verify -f "$WORK/allowed" -I test-release-signing \
      -n freedomtechfeed-release-manifest -s SHA256SUMS.sig < SHA256SUMS >/dev/null 2>&1); then
  pass "signature verifies against the pinned public key"
else
  fail "signature does not verify against the pinned public key"
fi
printf 'other-release-signing %s\n' "$(cat "$OTHER_KEY.pub")" > "$WORK/allowed-other"
if (cd "$WORK/signed" && ssh-keygen -Y verify -f "$WORK/allowed-other" -I other-release-signing \
      -n freedomtechfeed-release-manifest -s SHA256SUMS.sig < SHA256SUMS >/dev/null 2>&1); then
  fail "a DIFFERENT key verified the manifest — pinning is meaningless"
else
  pass "a different key is rejected (the pin is load-bearing)"
fi

# --------------------------------------------------------- missing asset
stage "$WORK/missing" --drop "$FIRST_ASSET"
if FEED_SIGNING_KEY="$KEYBODY" run "$WORK/missing" "$WORK/expected.txt"; then
  fail "missing-asset: expected the job to fail, it succeeded"
else
  grep -q "$FIRST_ASSET" "$WORK/out.log" \
    && pass "a release missing a matrix asset fails and names it" \
    || fail "missing-asset failed for the wrong reason: $(tail -n1 "$WORK/out.log")"
fi

# ------------------------------------------------------- unmanaged asset
stage "$WORK/extra"
printf 'hand-attached\n' > "$WORK/extra/unmanaged-thing.bin"
if FEED_SIGNING_KEY="$KEYBODY" run "$WORK/extra" "$WORK/expected.txt"; then
  fail "unmanaged-asset: expected the job to fail, it succeeded"
else
  grep -q 'unmanaged-thing.bin' "$WORK/out.log" \
    && pass "an asset outside the expected set fails and names it" \
    || fail "unmanaged-asset failed for the wrong reason: $(tail -n1 "$WORK/out.log")"
fi

# ----------------------------------------------------------- empty asset
stage "$WORK/empty" --empty "$FIRST_ASSET"
if FEED_SIGNING_KEY="$KEYBODY" run "$WORK/empty" "$WORK/expected.txt"; then
  fail "empty-asset: expected the job to fail, it succeeded"
else
  pass "an empty asset fails"
fi

# ----------------------------------------- stale manifest vs changed bytes
stage "$WORK/stale"
FEED_SIGNING_KEY="$KEYBODY" run "$WORK/stale" "$WORK/expected.txt" >/dev/null 2>&1
printf 'x' >> "$WORK/stale/$FIRST_ASSET"
if (cd "$WORK/stale" && sha256sum --check --strict SHA256SUMS >/dev/null 2>&1); then
  fail "a manifest did not catch bytes that changed after it was written"
else
  pass "bytes changed after hashing fail sha256sum --check"
fi
if (cd "$WORK/stale" && ssh-keygen -Y verify -f "$WORK/allowed" -I test-release-signing \
      -n freedomtechfeed-release-manifest -s SHA256SUMS.sig < SHA256SUMS >/dev/null 2>&1); then
  pass "the signature still verifies (it authenticates the manifest, and the hash check catches the bytes)"
else
  fail "signature verification broke"
fi

# --------------------------------------------------- legacy (no expected)
stage "$WORK/legacy"
rm -f "$WORK/legacy/$FIRST_ASSET"
if FEED_SIGNING_KEY="$KEYBODY" run "$WORK/legacy"; then
  legacy_lines=$(grep -c . "$WORK/legacy/SHA256SUMS" || true)
  if [ "$legacy_lines" = "$((EXPECTED_COUNT - 1))" ]; then
    pass "legacy mode covers every file present, with no expected-set file"
  else
    fail "legacy mode wrote $legacy_lines entries, want $((EXPECTED_COUNT - 1))"
  fi
else
  fail "legacy mode: $(tail -n2 "$WORK/out.log")"
fi

# ------------------------------------------------------------------ summary
echo "-----------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
