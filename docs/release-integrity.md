# Release integrity: the per-release `SHA256SUMS` manifest

Audit finding **C3-05** (from `tollgate-installer` C2-I-02/C2-I-03 work and PR
OpenTollGate/tollgate-installer#43): this feed published releases whose only
published digest was the GitHub release API's per-asset `digest`. That digest
arrives over the same channel as the bytes it describes, so an installer
fitting "verify the downloaded package against the feed's published digest" had
no anchor that survives a compromise of the release itself.

Every release now carries a manifest, and that manifest is signed.

## What is published

For a release tagged `<tag>`, in addition to the 8–14 `tollgate-wrt_*` assets:

| asset | content |
|---|---|
| `SHA256SUMS` | one line per release asset: `<64-hex sha256>  <asset name>` |
| `SHA256SUMS.sig` | SSHSIG signature of `SHA256SUMS` (OpenSSH `ssh-keygen -Y sign`) |

The manifest format is GNU coreutils (`sha256sum` output): LF line endings,
entries sorted by asset name, the file name bare (no `./`). That is the shape
`pkgverify.go`'s `parseChecksumManifestFor` parses, including its `./`-prefix
and `*` binary-mode tolerance.

## Verify a release

```sh
TAG=v0.6.0-alpha4-pre15
BASE="https://github.com/FreedomTechFeed/packages/releases/download/$TAG"
curl -fsSL "$BASE/SHA256SUMS" -o SHA256SUMS
sha256sum --check --strict SHA256SUMS   # after fetching the package(s) you care about
```

Authenticate the digest itself — the manifest is only an independent anchor
when its signature is checked against a pinned key:

```sh
curl -fsSL "$BASE/SHA256SUMS.sig" -o SHA256SUMS.sig
curl -fsSL https://raw.githubusercontent.com/FreedomTechFeed/packages/master/.github/release-keys/allowed_signers -o allowed_signers
ssh-keygen -Y verify -f allowed_signers \
  -I release-signing@freedomtechfeed \
  -n freedomtechfeed-release-manifest \
  -s SHA256SUMS.sig < SHA256SUMS
# -> Good "freedomtechfeed-release-manifest" signature for release-signing@freedomtechfeed
#    with ED25519 key SHA256:lQWK9yivuF2bVKLTYaKlu2X3zgRdgfbQf1ymAazgets
```

Pin the key by its fingerprint, not by the file's URL:

```
pinned public key : ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDcUgwqi2tGQlI0ElHJofqNxpl71QefUpzRE5gCNU7H release-signing@freedomtechfeed
fingerprint       : SHA256:lQWK9yivuF2bVKLTYaKlu2X3zgRdgfbQf1ymAazgets (ED25519)
identity (-I)     : release-signing@freedomtechfeed
namespace  (-n)   : freedomtechfeed-release-manifest
```

Also committed verbatim at
`.github/release-keys/release-signing.pub` and
`.github/release-keys/allowed_signers`.

## Why SSHSIG (ed25519) and not minisign/GPG

* `ssh-keygen -Y sign/verify` ships with every GitHub runner and with every
  operator workstation — no extra binary to vendor, download or trust.
* The pinned artefact is a single `ssh-ed25519` line, which is trivial to embed
  as a Go string constant in the installer.
* `tollgate-installer` already imports `golang.org/x/crypto/ssh`, so verifying
  an SSHSIG against such a constant needs no new dependency (see the sketch
  below). minisign or an age/ed25519 raw signature would each add a dependency
  for the same guarantee; GPG adds a whole keyring.

### Verifying in Go (installer side — reference only)

PR #43 must keep verifying against the GitHub release API until a *signature*
check is added; parsing the manifest alone is still same-origin. What the
signature check needs:

```go
import "golang.org/x/crypto/ssh"

const pinnedReleaseKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDcUgwqi2tGQlI0ElHJofqNxpl71QefUpzRE5gCNU7H release-signing@freedomtechfeed"
const manifestNamespace = "freedomtechfeed-release-manifest"
```

`ssh-keygen -Y sign` emits the `SSHSIG` envelope defined in OpenSSH's
`PROTOCOL.sshsig` (an ASCII-armoured blob with a `-----BEGIN SSH SIGNATURE-----`
header). Verifying it is ~40 lines and needs no new dependency: `ssh.Unmarshal`
the envelope into a struct, rebuild the signed message
(`MAGIC || namespaceLen || namespace || reserved || hashAlg || H(msg)`), and call
`pub.Verify(...)` with the parsed `ssh.PublicKey`. The pinned public key line
above is the whole trust anchor; nothing else in the path needs to be trusted —
which is exactly why the key is pinned in the binary rather than fetched.

## How it is produced

* `.github/workflows/scripts/release-assets.py` — the single source of truth for
  the arch matrix **and** the expected asset names. The release matrix is
  generated from it, so matrix and manifest can never drift.
* `.github/workflows/scripts/release-manifest.sh` — hashes the asset directory,
  writes `SHA256SUMS`, re-verifies it against the bytes on disk, signs it with
  `FEED_SIGNING_KEY`, and self-verifies the signature before anything is
  uploaded. It **refuses to emit an unsigned manifest** unless
  `ALLOW_UNSIGNED=1` is set deliberately.
* `.github/workflows/release-publish.yml` — the release job. It fails if the
  staged asset set is not exactly the expected set, or if the release already
  carries an unmanaged asset; it holds the release as a **draft** until every
  package and the manifest are uploaded and then publishes it in one step, so
  there is no window in which the tag resolves for an installer while
  `SHA256SUMS` 404s; and it re-downloads the manifest and every asset from the
  public release URL and runs `sha256sum --check` before the run is green.
* `.github/workflows/release-manifest-backfill.yml` — repair path for the
  releases published before this landed (`v0.6.0-alpha1` …
  `v0.6.0-alpha4-pre15`). `workflow_dispatch` with an empty `tags` input
  backfills every published release that still has no manifest; each leg checks
  the download against the release's own asset count, then verifies the result
  through the public URL. New releases must NOT rely on it.

Key material lives in the repository secret `FEED_SIGNING_KEY` (OpenSSH
ed25519 private key, generated 2026-09-23). Rotation: generate a new keypair,
set the new private key as `FEED_SIGNING_KEY`, commit the new public half to
`.github/release-keys/`, and re-run the backfill with `tags` filled in to
re-sign historical releases — the old key stays in `allowed_signers` only if
old signatures must keep verifying.

## Threat model — what this does and does not buy

Catches, because the signature is checked against a key that is **not** served
by the release host:

* a manifest/tag pair that is edited by whoever can write to the release — they
  cannot re-sign without the private key;
* a truncated or substituted package, once the installer checks the bytes
  against a signed manifest;
* a partially-published release, which now fails the release job instead of
  publishing silently checksum-less.

Does not catch:

* compromise of the `FEED_SIGNING_KEY` secret or of the account that can read
  it — as with any signing key, custody is the boundary;
* an installer that parses `SHA256SUMS` **without** verifying
  `SHA256SUMS.sig`: a same-origin manifest is self-consistent, never
  authentic. This is why PR #43 keeps the release-API digest as its only
  independent source until signature verification is added.
