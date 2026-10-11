# Resolving a tollgate-wrt download URL

The release **tag** and the package **asset name** are not the same string. Any
handoff, wizard entry or operator note that treats them as interchangeable will
produce a URL that 404s — or worse, an empty variable that produces a URL that
looks plausible.

## The two traps

Field incident (2026-10-11, router recovery over SSH):

```
$TAG and $VER were both empty -- the URL proved it:
  https://github.com/FreedomTechFeed/packages/releases/download//tollgate-wrt__aarch64_cortex-a53.apk
                                                              ^^ nothing here                       ^^ nothing here
```

1. **The resolver needed `gh`.** The snippet computed the tag with the GitHub
   CLI, which OpenWrt does not ship. Both variables came out empty, and an empty
   variable in a URL is not an error — it is a silent double slash.
2. **`$VER` can never be copied from `$TAG`.** The two strings differ by a
   leading `v` and by `-` vs `_`:

| what | value |
|---|---|
| git tag | `v0.6.0-rc1-pre29` |
| package version (`PKG_VERSION` in `net/tollgate-wrt/Makefile`) | `0.6.0_rc1_pre29` |
| asset | `tollgate-wrt_0.6.0_rc1_pre29_aarch64_cortex-a53.apk` |

The transformation is mechanical and total:

* tag → version: drop a leading `v`, replace every `-` with `_`
* version → tag: prefix `v`, replace every `_` with `-`

`PKG_VERSION` is apk-legal, so it uses underscores and never hyphens
(`net/tollgate-wrt/Makefile`); this is why the transform is unambiguous in both
directions. `.github/workflows/scripts/release-assets.py` is the single source of
truth for the asset *name*; this document adds the *tag* half of the mapping.

## Resolve it without `gh`, `python` or a network call

`scripts/tollgate-release-url.sh` needs a POSIX shell only (busybox `ash` on the
router included) and refuses to emit a URL it cannot construct:

```sh
sh scripts/tollgate-release-url.sh v0.6.0-rc1-pre29 aarch64_cortex-a53
# https://github.com/FreedomTechFeed/packages/releases/download/v0.6.0-rc1-pre29/tollgate-wrt_0.6.0_rc1_pre29_aarch64_cortex-a53.apk

sh scripts/tollgate-release-url.sh 0.6.0_rc1_pre29 mips_24kc ipk   # version form, opkg lane
sh scripts/tollgate-release-url.sh --arches                       # club arch tuples
```

Empty input, a malformed version or an unknown extension are hard errors
(exit 3) with a message, never an empty string in the URL.

## Self-gating variant for handoffs

`--check` downloads the asset, requires it to be listed in the release's
`SHA256SUMS`, and compares digests. It exits non-zero on any mismatch, so a
handoff that runs it cannot proceed on a wrong or absent URL:

```sh
sh scripts/tollgate-release-url.sh --check v0.6.0-rc1-pre29 aarch64_cortex-a53
# OK  https://github.com/.../tollgate-wrt_0.6.0_rc1_pre29_aarch64_cortex-a53.apk
#     sha256 fceb5455...a6946
```

`SHA256SUMS` is only an independent anchor once its signature is verified — see
`docs/release-integrity.md` for the SSHSIG check against the pinned
`release-signing@freedomtechfeed` key.

## Rules for handoffs

* Never resolve a release tag on the router. Compute the URL on a machine with
  the tools, verify it (`--check`), and paste the resolved URL.
* Never let an empty variable into a URL. Use `set -u`, or better, use this
  script, which makes the empty case an error you can see.
* When a URL must be typed by hand, `--check` it first. A double slash in the
  path is the signature of this bug.
