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

## Supported devices

"Supported" in this feed is **arch + target** level, not per-device. The build
matrix (`release-assets.py` `RELEASES`) and the release matrix are keyed on the
OpenWrt arch tuple and target, so any device that reports one of those tuples is
built and published; there is no per-device matrix entry to add.

The **Cudy WR3000 v1** (`cudy,wr3000-v1`) is a supported `aarch64_cortex-a53` /
`mediatek-filogic` device, covered by the existing matrix entry and by the
existing `aarch64_cortex-a53` offline bundle. Its OpenWrt device profile in
`profiles.json` is `cudy_wr3000-v1`.

| device profile     | device                       | arch tuple           | target             | flash         |
|--------------------|------------------------------|----------------------|--------------------|---------------|
| `cudy_wr3000-v1`   | Cudy WR3000 v1               | `aarch64_cortex-a53` | `mediatek-filogic` | 16 MB SPI-NOR |
| `glinet_gl-mt3000` | GL-MT3000 (MT3000-class bench)| `aarch64_cortex-a53` | `mediatek-filogic` | —             |

### Capacity caveat — Cudy WR3000 v1

The router carries 16 MB of SPI-NOR flash. The `tollgate-wrt` payload is 21 MB
uncompressed (`/usr/bin/tollgate-wrt` 12,361,280 B + `/usr/bin/tollgate`
7,373,632 B) and 8.5 MB compressed, while only ~4.6 MB of jffs2 overlay is free,
so a **persistent** package install fails with `ENOSPC` and only a **volatile**
(tmpfs) install fits. The 37-package dependency closure (`nodogsplash` 5.0.2-r2
+ `jq` + `libmicrohttpd-no-ssl` + `iptables-nft` + its kmods) installs normally;
only the payload does not fit. Measured on OpenWrt 25.12.5 r33051-f5dae5ece4,
board `cudy,wr3000-v1`.

### Offline bundles are per-arch, not per-device

The offline bundle is named `tollgate-wrt-<PKG_VERSION>-<arch>-offline.tar.gz`
and there is exactly one per arch. `release-assets.py`'s `OFFLINE_BUNDLES` table
and the `release-tooling.yml` self-test both assert that the bundle build matrix
has one entry per expected bundle asset name, and the installer wizard's
`tollgateArchAssets` map fetches the bundle by arch. A second bundle for the
Cudy would collide with the existing `aarch64_cortex-a53` bundle name, so no
per-device bundle entry is added.

A device is still a real input to the bundle: the `profile` column of
`OFFLINE_BUNDLES` (passed to `offline-bundle.py --profile`) names the
`profiles.json` profile whose `device_packages` are assumed to already be in the
base image. The `aarch64_cortex-a53` bundle assumes `glinet_gl-mt3000`, whose
`device_packages` (`kmod-mt7915e`, `kmod-mt7981-firmware`, `mt7981-wo-firmware`,
`kmod-hwmon-pwmfan`, `kmod-usb3`) are a **superset** of the Cudy WR3000 v1's
(`kmod-mt7915e`, `kmod-mt7981-firmware`, `mt7981-wo-firmware`). The two extra
kmods are not in `tollgate-wrt`'s dependency closure, so the existing bundle is
correct for the Cudy and needs no per-device variant.

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
