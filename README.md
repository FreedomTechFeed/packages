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
> The `tollgate-wrt` payload is 21 MB uncompressed (8.5 MB compressed) and only
> ~4.6 MB of jffs2 overlay is free, so a persistent package install fails with
> `ENOSPC`; only a volatile (tmpfs) install fits. The 37-package dependency
> closure installs normally — only the payload does not fit.

See [docs/per-arch-release-assets.md](docs/per-arch-release-assets.md) for the
arch/target matrices, the device profiles, and the offline install bundle.

## License

See [LICENSE](LICENSE) file.
 
## Package Guidelines

See [CONTRIBUTING.md](CONTRIBUTING.md) file.

