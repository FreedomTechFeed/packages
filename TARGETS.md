# Validation tracking — per-arch / per-target TollGate installs

This is the **source of truth** for which OpenWrt `arch` / `target` pairs have
been validated to install and run `tollgate-wrt`, and by whom. The published
release assets are named per `(arch, target)`:

```
tollgate-wrt_<PKG_VERSION>_<arch>-<target>.apk         # OpenWrt 25.12+ (apk)
tollgate-wrt_<PKG_VERSION>_<arch>-<target>.ipk         # OpenWrt 24.10  (opkg)
tollgate-wrt-<PKG_VERSION>-<arch>-<target>-offline.tar.gz  # WAN-less bundle
```

You can resolve the URL for your router with:

```sh
scripts/tollgate-release-url.sh v0.6.0-rc6 <arch> <target>          # apk lane
scripts/tollgate-release-url.sh 0.6.0_rc6 <arch> <target> ipk       # opkg lane
```

Find your router's pair on it:

```sh
# on the router
. /etc/openwrt_release
echo "arch=${DISTRIB_ARCH}  target=$(echo "$DISTRIB_TARGET" | tr / -)"
```

## Status

`validated` = an installer/upgrade was run on real hardware and the service came
up (API `:2121` + the board/portal ports); `pending` = a device is being lined
up; `—` = not yet attempted.

| arch | target | example device | validated by | date | RC | notes |
|------|--------|----------------|--------------|------|----|-------|
| `aarch64_cortex-a53` | `mediatek-filogic` | GL-MT3000, GL-MT6000, Cudy WR3000, CF-WR632AX | c03rad0r | 2026-10-15 | rc6 | MT3000 (apk/25.12.5) + MT6000 (opkg/24.10.2) upgraded in place to `0.6.0_rc6-r1`; service + all entry ports up. CF-WR632AX shares this target (OpenWrt profiles `comfast_cf-wr632ax` / `-ubootmod`) so the same published assets apply, but no install has been run on that device yet |
| `mips_24kc` | `ath79-generic` | GL.iNet AR300M `-lite` / `-16` | — | — | rc6 | build + offline bundle published; hardware validate pending |
| `mips_24kc` | `ath79-nand` | GL.iNet AR300M `-nor` / `-nand` | — | — | rc6 | newly un-parked in rc6 (target-qualified names end the arch-only collision) |
| `aarch64_cortex-a72` | `bcm27xx-bcm2711` | Raspberry Pi 4 family | — | — | rc6 | |
| `arm_cortex-a7_neon-vfpv4` | `bcm27xx-bcm2709` | Raspberry Pi 2 family | — | — | rc6 | arch is `…_neon-vfpv4` (the target's package arch), not bare `arm_cortex-a7` |
| `mipsel_24kc` | `ramips-mt7621` | MT7621 routers | — | — | rc6 | target is the full path `ramips-mt7621` |
| `mips64_octeonplus` | `octeon-generic` | Octeon boards | — | — | rc6 | |
| `x86_64` | `x86-64` | x86 VMs / boxes | — | — | rc6 | |

`aarch64_generic` / `armsr-armv8` (generic ARM SystemReady) is intentionally
**not** shipped — it is not a device the review club runs. Its restore path is
kept visible (parked) in `release-assets.py`, and `net/tollgate-wrt/test-feed-ci.sh`
Gate K enforces that.

## Device coverage vs arch coverage — what a row here does and does not mean

A row is keyed on the **(arch, target) pair**, so it covers **every device in that
target**, not only the ones named in the `example device` column. Naming a device
adds no build and no asset: the target's already-published
`tollgate-wrt_<version>_<arch>-<target>.{apk,ipk}` and its offline bundle apply
unchanged.

Two things a row does **not** guarantee, both measured (2026-10-16) for
CF-WR632AX on `aarch64_cortex-a53` / `mediatek-filogic`:

1. **The offline bundle's assumed base image.** `OFFLINE_BUNDLES` in
   `.github/workflows/scripts/release-assets.py` carries a **device `profile`**
   whose `device_packages` are assumed already present, so they are omitted from
   the WAN-less bundle. That row names `glinet_gl-mt3000`. Checked against
   OpenWrt 25.12.5 `targets/mediatek/filogic/profiles.json`: the MT3000 and
   CF-WR632AX profiles declare the **same five** `device_packages`
   (`kmod-hwmon-pwmfan`, `kmod-mt7915e`, `kmod-mt7981-firmware`, `kmod-usb3`,
   `mt7981-wo-firmware`), so the existing bundle is sufficient for CF-WR632AX and
   no `OFFLINE_BUNDLES` change is needed. A device whose profile assumes **fewer**
   packages than the row's would need its own bundle row — that is the check to
   repeat per device, and `profile ""` (default_packages only) is the safe
   direction.

2. **The onboarding wizard's model table.** A published asset with no wizard entry
   is **invisible** — the operator gets "Unknown GL.iNet model" and must flash by
   hand. That table is `glModelMap` in
   `OpenTollGate/tollgate-installer` (`internal/app/images.go`), reached through
   `glModelFromBoard` (`internal/app/deploy.go`), which normalises an OpenWrt
   `board_name` into a map key. **CF-WR632AX is absent from it**, and its
   `board_name` is `comfast,cf-wr632ax` (OpenWrt declares
   `SUPPORTED_DEVICES += cf-wr632ax` on the COMFAST device), so the current prefix
   guard — which accepts only `gl-` — rejects it. Adding the model requires the
   map entry **and** widening that guard; see the installer PR that follows.

> **Stale pointer, fixed here:** this file previously referred to the wizard's
> device list as `net4sats-wizard-go arch.go`. That project has been retired in
> favour of `OpenTollGate/tollgate-installer`, so the reference now points at the
> repo that actually ships.

## How to add your result (open a PR)

1. Install (or upgrade to) the RC on your router and confirm the service is up:
   ```sh
   . /etc/openwrt_release; echo "$DISTRIB_ARCH $(echo "$DISTRIB_TARGET" | tr / -)"
   opkg list-installed | grep tollgate-wrt   # or: apk list -I | grep tollgate-wrt
   /etc/init.d/tollgate-wrt status
   ```
2. Add (or update) your row in the table above:
   - fill the **validated by** column with the name/handle you want shown,
   - the **date** (`YYYY-MM-DD`), the **RC** (e.g. `rc6`), and a short **notes**
     line (router model, OpenWrt version, package manager, anything that
     surprised you),
   - keep rows sorted by `arch` then `target`.
3. Open a pull request titled `TARGETS: validate <arch>/<target> on <device>`.
   One row per PR is fine; batch if you validated several.

If your router's `(arch, target)` pair is **not** in the table, it is not a
published target — open an issue with the pair and we will decide whether to add
it (and its offline bundle) to the matrix.

## Devices that would broaden coverage

A validation for any `—` row above is welcome. The most valuable are hardware
you actually run: an AR300M `-nand` variant (proves the un-park), and any
`mt7621` (the `ramips-mt7621` target path). A Raspberry Pi or x86 box is great
for the non-router targets.
