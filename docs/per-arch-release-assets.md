# Per-arch tollgate-wrt release assets

The feed publishes tollgate-wrt packages for every router architecture the
wizard can select, at stable, deterministic URLs. This is the Phase 2
prerequisite for "test the feed via the installer": the wizard's
`tollgateArchAssets` map (in `net4sats-wizard-go` `arch.go`) points at these
URLs so the correct binary is fetched for the detected router arch.

## Asset naming

Each release asset is named:

```
tollgate-wrt_<PKG_VERSION>_<arch>.apk
tollgate-wrt_<PKG_VERSION>_<arch>.ipk
```

`PKG_VERSION` is read from `net/tollgate-wrt/Makefile` (e.g. `0.6.0_alpha1`),
`<arch>` is the canonical OpenWrt arch tuple. Example:

```
tollgate-wrt_0.6.0_alpha1_aarch64_cortex-a53.apk
tollgate-wrt_0.6.0_alpha1_aarch64_cortex-a53.ipk
```

## Which arches are published

The wizard can select these canonical tuples (see `arch.go`):

| arch tuple            | target             | bench device        |
|-----------------------|--------------------|---------------------|
| `aarch64_cortex-a53`  | `mediatek-filogic` | GL-MT6000 (bench)   |
| `mipsel_24kc`         | `mt7621`           | MT3000-class        |
| `mips_24kc`           | `ath79-generic`    | —                   |
| `x86_64`              | `x86-64`           | gl-gate             |

## How it works

### Test build (`multi-arch-test-build.yml`)

Runs on every pull request. It calls the openwrt shared
`multi-arch-test-build` workflow with a **custom matrix override** that adds
`aarch64_cortex-a53`/`mediatek-filogic` alongside the existing arches. The
shared workflow's default matrix does NOT include the bench GL-MT6000 arch, so
the override is mandatory — without it the bench router's arch never builds.

### Release publish (`release-publish.yml`)

Triggers on `v*` tags (and `workflow_dispatch`). For each arch it builds
tollgate-wrt with two SDK images:

- `master` → apk-tools package (`.apk`), OpenWrt 25+
- `openwrt-24.10` → opkg package (`.ipk`), OpenWrt <=24.x

This mirrors how the wizard selects `.apk` vs `.ipk` by package manager. Build
jobs run in parallel and upload their per-arch asset as a workflow artifact; a
single `publish` job downloads them all and uploads to the release. This
avoids the race of several matrix jobs calling `softprops/action-gh-release`
concurrently.

## Verification

```sh
sh net/tollgate-wrt/test-feed-ci.sh   # TDD harness, must exit 0
```

The harness asserts:

1. The build matrix references `aarch64_cortex-a53`/`mediatek-filogic`.
2. A release/tag-triggered workflow uploads per-arch assets.
3. The deterministic `tollgate-wrt_<version>_<arch>` naming pattern is
   encoded.
4. The existing `mipsel_24kc` / `mips_24kc` / `x86_64` builds are preserved.
