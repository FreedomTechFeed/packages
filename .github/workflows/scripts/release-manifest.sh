#!/usr/bin/env bash
#
# Build the per-release SHA256SUMS manifest for a directory of release assets,
# verify that it covers every asset, and sign it.
#
# Usage:
#   release-manifest.sh <asset-dir> [expected-assets-file]
#
#   <asset-dir>              directory holding the release assets to hash
#   <expected-assets-file>   file with one expected asset name per line; the
#                            directory must contain EXACTLY these assets and
#                            nothing else. Omit for legacy releases whose arch
#                            matrix differed (then every file present is
#                            covered, and the caller asserts the file count
#                            against the release's own asset list).
#
# Signing: if FEED_SIGNING_KEY holds an OpenSSH-format ed25519 private key, the
# manifest is signed with ssh-keygen -Y sign into SHA256SUMS.sig (SSHSIG), and
# the signature is immediately self-verified against the committed public key.
# Without a key the script FAILS unless ALLOW_UNSIGNED=1 is set, because a
# silently-unsigned manifest is exactly the failure mode this exists to stop.
#
# Outputs (written INSIDE <asset-dir>): SHA256SUMS, and SHA256SUMS.sig when
# signed. The manifest format is GNU coreutils: "<64-hex>  <name>", UTF-8,
# LF line endings, entries sorted by name — the shape the installer's
# pkgverify.go parser (parseChecksumManifestFor) expects.

set -euo pipefail

SIG_NAMESPACE="freedomtechfeed-release-manifest"
SIG_IDENTITY="release-signing@freedomtechfeed"
MANIFEST="SHA256SUMS"
SIGNATURE="SHA256SUMS.sig"

die() { echo "::error::$*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: release-manifest.sh <asset-dir> [expected-assets-file]"
ASSET_DIR="$1"
EXPECTED_FILE="${2:-}"
[ -d "$ASSET_DIR" ] || die "asset dir not found: $ASSET_DIR"
# Resolve before cd'ing into the asset dir: callers pass paths relative to repo
# root (e.g. .github/workflows/scripts/...) and to their own cwd.
ASSET_DIR="$(cd "$ASSET_DIR" && pwd)"
if [ -n "$EXPECTED_FILE" ]; then
  [ -f "$EXPECTED_FILE" ] || die "expected-assets file not found: $EXPECTED_FILE"
  EXPECTED_FILE="$(cd "$(dirname "$EXPECTED_FILE")" && pwd)/$(basename "$EXPECTED_FILE")"
fi

cd "$ASSET_DIR"

# ---------------------------------------------------------------- collect set
# Every regular file except the manifest/signature itself is an asset that the
# manifest MUST cover.
mapfile -t ASSETS < <(find . -maxdepth 1 -type f \
  ! -name "$MANIFEST" ! -name "$SIGNATURE" -printf '%f\n' | LC_ALL=C sort)
[ "${#ASSETS[@]}" -gt 0 ] || die "no assets found in $PWD — refusing to publish an empty manifest"
for name in "${ASSETS[@]}"; do
  [ -s "$name" ] || die "asset is empty: $name"
done

if [ -n "$EXPECTED_FILE" ]; then
  [ -f "$EXPECTED_FILE" ] || die "expected-assets file not found: $EXPECTED_FILE"
  mapfile -t EXPECTED < <(grep -v '^[[:space:]]*$' "$EXPECTED_FILE" | LC_ALL=C sort)
  # Missing asset -> a partially-published release. Fail loudly.
  MISSING=$(comm -23 <(printf '%s\n' "${EXPECTED[@]}") <(printf '%s\n' "${ASSETS[@]}") || true)
  [ -z "$MISSING" ] || die "release is missing expected asset(s):
$MISSING"
  # Unmanaged asset -> the manifest cannot describe it. Fail loudly.
  UNEXPECTED=$(comm -13 <(printf '%s\n' "${EXPECTED[@]}") <(printf '%s\n' "${ASSETS[@]}") || true)
  [ -z "$UNEXPECTED" ] || die "release carries asset(s) not in the expected set:
$UNEXPECTED"
  echo "asset set matches the expected ${#EXPECTED[@]} entries"
fi

# ------------------------------------------------------------- hash + write
rm -f "$MANIFEST" "$SIGNATURE"
: > "$MANIFEST"
for name in "${ASSETS[@]}"; do
  digest=$(sha256sum -- "$name" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$name" >> "$MANIFEST"
done
LC_ALL=C sort -k2 -o "$MANIFEST" "$MANIFEST"

# Re-hash what we just wrote: the manifest must verify against the bytes on
# disk before anything leaves this job.
if ! sha256sum --check --strict "$MANIFEST" >/dev/null; then
  die "generated manifest does not verify against the staged assets"
fi

echo "--- $MANIFEST (${#ASSETS[@]} entries)"
cat "$MANIFEST"

# ------------------------------------------------------------------- sign
if [ -n "${FEED_SIGNING_KEY:-}" ]; then
  KEY_FILE="$(mktemp)"
  trap 'rm -f "$KEY_FILE"' EXIT
  printf '%s\n' "$FEED_SIGNING_KEY" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  ALLOWED="$(mktemp)"
  printf '%s %s\n' "$SIG_IDENTITY" "$(ssh-keygen -y -f "$KEY_FILE")" > "$ALLOWED"
  # -Y sign writes <file>.sig next to the manifest.
  ssh-keygen -Y sign -f "$KEY_FILE" -n "$SIG_NAMESPACE" "$MANIFEST" >/dev/null
  [ -s "$MANIFEST.sig" ] || die "signing produced no signature"
  # Self-verify with the public half derived from the same key: catches a
  # truncated key, a wrong namespace, or a signature we could not verify.
  ssh-keygen -Y verify -f "$ALLOWED" -I "$SIG_IDENTITY" -n "$SIG_NAMESPACE" \
    -s "$MANIFEST.sig" < "$MANIFEST" >/dev/null \
    || die "self-verification of the manifest signature FAILED"
  echo "signed: $MANIFEST.sig (SSHSIG, namespace $SIG_NAMESPACE, identity $SIG_IDENTITY)"
  echo "signer fingerprint: $(ssh-keygen -lf "$ALLOWED" | awk '{print $2}')"
elif [ "${ALLOW_UNSIGNED:-0}" = "1" ]; then
  echo "::warning::FEED_SIGNING_KEY is not configured — publishing an UNSIGNED manifest"
else
  die "FEED_SIGNING_KEY is not configured: refusing to publish an unsigned manifest (set ALLOW_UNSIGNED=1 to override deliberately)"
fi
