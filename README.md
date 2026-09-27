# OpenWrt packages feed

## Description

This is the OpenWrt "packages"-feed containing community-maintained build scripts, options and patches for applications, modules and libraries used within OpenWrt.

Installation of pre-built packages is handled directly by the **opkg** utility within your running OpenWrt system or by using the [OpenWrt SDK](https://openwrt.org/docs/guide-developer/using_the_sdk) on a build system.

## Usage

This repository is intended to be layered on-top of an OpenWrt buildroot. If you do not have an OpenWrt buildroot installed, see the documentation at: [OpenWrt Buildroot – Installation](https://openwrt.org/docs/guide-developer/build-system/install-buildsystem) on the OpenWrt support site.

This feed is enabled by default. To install all its package definitions, run:
```
./scripts/feeds update packages
./scripts/feeds install -a -p packages
```

## Supported devices

The feed builds `tollgate-wrt` for the architectures the installer wizard can
select. Alongside the bench GL-MT6000, the **Cudy WR3000 v1**
(`cudy,wr3000-v1`, OpenWrt device profile `cudy_wr3000-v1`) is a supported
`aarch64_cortex-a53` / `mediatek-filogic` device.

> **Capacity caveat (Cudy WR3000 v1).** The router has 16 MB of SPI-NOR flash.
> The **default** `tollgate-wrt` payload is 21 MB uncompressed (8.5 MB
> compressed) and only ~4.6 MB of jffs2 overlay is free, so a default install
> fails with `ENOSPC`; a volatile (tmpfs) install is the fallback. The
> **`upx-ultra-brute`** variant (built by the module repo's CI for the same
> arch/target) shrinks the payload to **5.34 MiB**, which does fit — a real
> WR3000 v1 installed it, rebooted, and kept running it. That variant is **not
> yet published by this feed's release job**; only the default builds are.

See [docs/per-arch-release-assets.md](docs/per-arch-release-assets.md) for the
arch/target matrices, the device profiles, and the offline install bundle.

## License

See [LICENSE](LICENSE) file.
 
## Package Guidelines

See [CONTRIBUTING.md](CONTRIBUTING.md) file.

