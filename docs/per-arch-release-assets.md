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

The **COMFAST CF-WR632AX** (`comfast,cf-wr632ax`) is likewise a supported
`aarch64_cortex-a53` / `mediatek-filogic` device — a WiFi-6 compact travel
router in the MediaTek MT7981 class. It reports an arch tuple and target that
this feed's matrices **already** cover, so no matrix entry was added for it
(same as the Cudy above). Its OpenWrt device profile in `profiles.json` is
`comfast_cf-wr632ax`.

| device profile     | device                       | arch tuple           | target             | flash         |
|--------------------|------------------------------|----------------------|--------------------|---------------|
| `cudy_wr3000-v1`   | Cudy WR3000 v1               | `aarch64_cortex-a53` | `mediatek-filogic` | 16 MB SPI-NOR |
| `comfast_cf-wr632ax` | COMFAST CF-WR632AX         | `aarch64_cortex-a53` | `mediatek-filogic` | 128 MiB SPI NAND |
| `glinet_gl-mt3000` | GL-MT3000 (MT3000-class bench)| `aarch64_cortex-a53` | `mediatek-filogic` | —             |

### Capacity caveat — Cudy WR3000 v1 (and the compressed variant that fits)

The router carries 16 MB of SPI-NOR flash. The **default** `tollgate-wrt`
payload is 21 MB uncompressed (`/usr/bin/tollgate-wrt` 12,361,280 B +
`/usr/bin/tollgate` 7,373,632 B) and 8.5 MB compressed, while only ~4.6 MB of
jffs2 overlay is free, so a default-build install fails with `ENOSPC` and a
**volatile** (tmpfs) install is the fallback. The 37-package dependency closure
(`nodogsplash` 5.0.2-r2 + `jq` + `libmicrohttpd-no-ssl` + `iptables-nft` + its
kmods) installs normally; only the default payload does not fit. Measured on
OpenWrt 25.12.5 r33051-f5dae5ece4, board `cudy,wr3000-v1`.

A 16 MB device is **not** limited to the volatile path. The module repo's CI
also builds **`upx-ultra-brute`** variants for `aarch64_cortex-a53` /
`mediatek-filogic`, and that payload is **5.34 MiB** in total
(`/usr/bin/tollgate-wrt` 3,389.5 KiB + `/usr/bin/tollgate` 1,823.8 KiB plus
~256 KiB of config and captive-portal files). A real WR3000 v1 installed that
`.apk`, rebooted, and came back with `tollgate-wrt` running and no volatile
helper — a **persistent** install on 16 MB. Two notes from that run: the
1.78 MiB `tollgate` CLI can be dropped after provisioning to leave room for the
`nodogsplash` closure, and the closure must be installed in **one** `apk add`
transaction because `apk add --force-non-repository <file>` performs a world
sync that removes packages previously installed from files.

### COMFAST CF-WR632AX — 128 MiB NAND, so no capacity caveat

The COMFAST CF-WR632AX carries **128 MiB of SPI NAND** flash, so the Cudy
capacity caveat above — which is specific to that router's 16 MB of SPI-NOR —
**does not apply here**. Both the default `tollgate-wrt` payload (~21 MB
uncompressed at the time of writing) and the dependency closure fit with room
to spare, and the device is not limited to a volatile (tmpfs) install or to the
compressed `upx-ultra-brute` variant. No measured flash numbers are quoted for
this device (see the honesty note below).

At the arch/target level the device needs **no new release-matrix entry**: it is
`aarch64_cortex-a53` / `mediatek-filogic`, already a row in every matrix
(`release-assets.py` `RELEASES`, the test-build and release-publish workflow
overrides), so the existing per-arch artifact is already produced for it.

Upstream OpenWrt **officially supports this device since 25.12.0**, and upstream
requires **25.12.5 or newer** when using the OpenWrt U-Boot layout, because a
memory-speed stability issue was fixed in 25.12.5 (upstream PRs #22929 /
#23416).

> **Honesty note.** This device has **not** been exercised on hardware. It is
> documented as supported on the strength of upstream OpenWrt support and the
> shared `aarch64_cortex-a53` / `mediatek-filogic` target+arch that this feed
> already builds; no test install or measured throughput has been performed. A
> tester with the device is being lined up, and this section will be updated
> with real numbers once that has happened.

### Compressed variants are built, but this feed does not publish them

The `upx-ultra-brute` artifacts are built by the module repo's CI and announced
over Nostr (NIP-94 kind 1063, tag `compression=upx-ultra-brute`), but the
release job here publishes only the default `.ipk`/`.apk` per
(arch, target) row — so today a small-flash device cannot fetch the compressed
variant from a release. Publishing the compressed variants (or a `small-flash`
bundle alongside the existing per-arch one) is a candidate change to this
repo's release matrix; it is not part of this documentation change.

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

Runs on every pull request. The workflow is **vendored** in this repo rather
than calling the openwrt shared workflow, for two reasons:

1. It always builds `tollgate-wrt`. The upstream "Determine changed packages"
   step only builds packages whose `*/Makefile` changed, so a workflow-only PR
   would build generic test packages and give **zero** signal about the package
   this feed exists to ship.
2. It carries a **custom matrix override** that adds
   `aarch64_cortex-a53`/`mediatek-filogic` alongside the existing arches. The
   shared workflow's default matrix does NOT include the bench GL-MT6000 arch,
   so without the override the bench router's arch never builds.

The runtime smoke test in that workflow is deliberately **non-blocking**
(`continue-on-error: true`): upstream `openwrt/actions-shared-workflows#130`
makes it fail deterministically (kmods feed 404) even when the package built
fine. The **Build** phase — which actually compiles `tollgate-wrt` — is the
gate.

#### The SDK branch is pinned to an immutable release (`openwrt-25.12`)

The Build phase is `openwrt/gh-action-sdk`, which downloads an SDK tarball and
verifies it against the `sha256sums` published beside it. **`snapshots/` is a
mutable tree**, so that verification can race its own inputs: measured
2026-10-01 on PR #46 (run `36842992536`, job `Test aarch64_cortex-a72`), the job
fetched `targets/bcm27xx/bcm2711/sha256sums` at 09:30:57 and the 266 MB SDK
tarball finished **12 minutes later** at 09:42:31 — upstream had rotated the
snapshot in between, so the verify step failed with `1 computed checksum did
NOT match`. Seven of the eight arch jobs passed on that run; only the one whose
SDK rotated mid-download died. Nothing about the pull request caused it, and it
costs a full ~30-minute job each time it lands.

A **released** version is immutable — `releases/<version>/targets/<target>/`
`sha256sums` and the SDK tarball it describes never change — so verifying a
download against them cannot race. The workflow therefore pins
`SDK_BRANCH=openwrt-25.12`, with a fail-closed guard that refuses
`main|master|snapshot*` rather than silently falling back to a snapshot.
`release-publish.yml` already builds its `openwrt-24.10` lane from a
release-branch SDK, so this is the same mechanism, not a new one.

`net/tollgate-wrt/test-feed-ci.sh` Gate H asserts the pin, and carries a
negative control that mutates a copy of the workflow back to `master` and
requires the check to refuse it — so the assertion cannot pass vacuously.

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
