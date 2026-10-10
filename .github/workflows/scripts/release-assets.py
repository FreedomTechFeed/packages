#!/usr/bin/env python3
"""Single source of truth for the per-release tollgate-wrt asset set.

Both the release build matrix and the release manifest are derived from the
table below, so the two can never drift apart: adding an arch to RELEASES
extends the matrix AND the expected asset list in the same commit. The same
holds for OFFLINE_BUNDLES, whose names must also be in the expected set --
otherwise the signed SHA256SUMS would not cover the bundle's hash.

Usage:
    release-assets.py matrix                  -> package build matrix JSON
    release-assets.py expected-packages <v>   -> package asset names
    release-assets.py offline-matrix          -> offline bundle build matrix JSON
    release-assets.py expected-offline <v>    -> offline bundle asset names
    release-assets.py expected <version>      -> EVERY release asset, one per line

<version> is the feed's PKG_VERSION (net/tollgate-wrt/Makefile), e.g.
0.6.0_alpha4_pre15; asset names are

    tollgate-wrt_<version>_<arch>.<ext>
    tollgate-wrt-<version>-<arch>-offline.tar.gz
"""
import json
import sys

# (arch, openwrt target, exact SDK version, package extension)
#
# SDK values are EXACT released versions (major.minor.patch), never branch
# tags: ghcr.io/openwrt/sdk branch-tag images (openwrt-25.12, openwrt-24.10)
# are snapshot-built and ship WITHOUT the SDK -- gh-action-sdk's entrypoint
# downloads the ~260 MB tarball from the OpenWrt mirrors in every job.
# Measured on the pre26 release run 37839847702 (2026-10-08): the apk-lane
# job (openwrt-25.12) spent 10,434 s on that download, the ipk-lane
# (openwrt-24.10) 3 h 38 m -- the release took 262 min wall with tollgate
# itself compiling in ~1 min per lane. Exact-version images (25.12.5,
# 24.10.8) BUNDLE the SDK: no tarball download at all, no sha256sums race,
# and the buildx gha-cache scope is stable per version. The pin is bumped by
# hand when we adopt a new OpenWrt release; keep it aligned with
# OFFLINE_BUNDLES below (both must name the release the routers run).
# Two SDK images are built per arch:
#   25.12.x (apk-tools era) -> .apk package, OpenWrt 25.12+
#   24.10.x (opkg era)      -> .ipk package, OpenWrt <=24.x
# The wizard selects .apk vs .ipk by the package manager it finds on the router
# (net4sats-wizard-go arch.go / tollgateArchAssets).
#
# The apk lane builds against the RELEASED 25.12 line, not the
# mutable `master` snapshot tree. Same rationale as the PR lane's SDK pin
# (multi-arch-test-build.yml, measured on PR #46): a snapshot rotates
# continuously, so (1) a tarball can stop matching the sha256sums fetched
# seconds earlier, and (2) the gh-action-sdk docker cache (scope
# openwrt/sdk-<arch>-master) can never hit for long — the moved snapshot
# forces the SDK image rebuild and the ~25-30 min dependency-closure source
# rebuild on every tag. A released branch is immutable: sums cannot race and
# the cache stays valid until the branch itself moves. Measured cost of the
# snapshot lane on the pre26 tag (run 37816851786, 2026-10-08): every build
# job rebuilt its closure from source; the slowest lane spent 2597 s of a
# 2630 s job inside openwrt/gh-action-sdk, with the tollgate module itself
# compiling in the final ~60 s. This also matches what ships: the routers run
# 25.12.5 (see OFFLINE_BUNDLES below), the PR lane pins an exact 25.12.x, so the
# release apk lane was the only lane still building against `master`.
# (arch, 
#  2026-10-08 (operator product call): the release lane ships exactly the
# arches the club runs -- GL-MT3000 + GL-MT6000 (aarch64_cortex-a53 /
# mediatek-filogic) and the GL.iNet AR300M family (mips_24kc /
# ath79-generic for -lite/-16, or ath79-nand for -nor/-nand). Every other
# row is PARKED, not deleted: uncomment a row
# to restore it. Gates D and K in net/tollgate-wrt/test-feed-ci.sh keep
# this honest (D: the club set keeps its .apk row + its offline bundle;
# K: every parked row is still a paste-back-able 4-tuple). Keep the parked
# block INSIDE the list so restoring a row is a one-line edit.
#
# Before restoring an arch here, also check the wizard's device list
# (net4sats-wizard-go arch.go) -- a shipped asset with no wizard entry is
# invisible, and a wizard entry with no asset 404s on install.
RELEASES = [
    # --- club devices: MT3000 + MT6000 (a53), AR300M family (mips_24kc) ---
    ("aarch64_cortex-a53", "mediatek-filogic", "25.12.5", "apk"),
    ("aarch64_cortex-a53", "mediatek-filogic", "24.10.8", "ipk"),
    ("mips_24kc", "ath79-generic", "25.12.5", "apk"),
    ("mips_24kc", "ath79-generic", "24.10.8", "ipk"),
    # --- PARKED (uncomment to restore; no club device needs these) -------
    # ("aarch64_cortex-a72", "bcm27xx-bcm2711", "25.12.5", "apk"),
    # ("aarch64_cortex-a72", "bcm27xx-bcm2711", "24.10.8", "ipk"),
    # ("arm_cortex-a7", "bcm27xx-bcm2709", "25.12.5", "apk"),
    # ("arm_cortex-a7", "bcm27xx-bcm2709", "24.10.8", "ipk"),
    # ("mipsel_24kc", "mt7621", "25.12.5", "apk"),
    # ("mipsel_24kc", "mt7621", "24.10.8", "ipk"),
    # ("mips64_octeonplus", "octeon-generic", "25.12.5", "apk"),
    # ("mips64_octeonplus", "octeon-generic", "24.10.8", "ipk"),
    # ("x86_64", "x86-64", "25.12.5", "apk"),
    # ("x86_64", "x86-64", "24.10.8", "ipk"),
    # AR300M alternatives, not additions: -lite/-16 use ath79/generic;
    # -nor/-nand use ath79/nand. All four share mips_24kc, so both targets
    # cannot be live at once: tollgate-wrt_<version>_mips_24kc.<ext> would collide.
    # ("mips_24kc", "ath79-nand", "25.12.5", "apk"),
    # ("mips_24kc", "ath79-nand", "24.10.8", "ipk"),
]

# Offline dependency bundles (WAN-less install), one per arch that ships the
# apk-tools 3 lane.
#
# (arch, target, OpenWrt release the bundle's dependency closure is resolved
#  against, device profile whose base-image packages are assumed, extension)
#
# `release` must be the OpenWrt release the router actually runs: the bundle
# carries kernel-module packages, and those are version-locked to it. `profile`
# decides which packages count as "already in the base image" (profiles.json
# default_packages + device_packages); pass "" to assume default_packages only,
# which bundles strictly more and is the safe direction.
#
# The .ipk / OpenWrt <= 24.x (opkg) lane has no offline bundle: its dependency
# story differs (no apk-tools 3, no .adb indexes) and it is out of scope.
OFFLINE_BUNDLES = [
    ("aarch64_cortex-a53", "mediatek-filogic", "25.12.5", "glinet_gl-mt3000", "apk"),
    # mips_24kc / ath79-generic (GL.iNet AR300M family, qca9531). Added
    # 2026-10-01: the apk lane had published this arch since the matrix landed,
    # but no bundle existed for it, so a mips_24kc router with NO uplink could
    # not resolve its 37-package closure and could not install. Measured: the
    # closure resolves to 37 members with 0 unresolved against the published
    # 25.12.5 ath79/generic indexes, and assembles to a 9.6 MB tarball.
    #
    # `profile` is glinet_gl-ar300m-lite -- the smallest AR300M profile
    # (NOR/Lite, IMAGE_SIZE 16000k). Its device_packages is `kmod-usb2` alone;
    # glinet_gl-ar300m16 is identical, and the NAND variants (-nor/-nand) live
    # in the ath79/nand target's profile set, not this ath79-generic lane's
    # (see the NAND note below). Assuming the smallest profile bundles
    # strictly MORE, which is the safe direction per the note above (the
    # bundle's packages are additive; an already-present package is skipped).
    # If the club unit is a NAND variant, repoint this bundle together with the
    # club release rows: target becomes ath79-nand and profile becomes a NAND
    # profile such as glinet_gl-ar300m-nor. The closure is resolved against the
    # target's indexes, so an ath79-generic bundle is not interchangeable.
    ("mips_24kc", "ath79-generic", "25.12.5", "glinet_gl-ar300m-lite", "apk"),
]


def matrix():
    return {
        "include": [
            {"arch": arch, "target": target, "sdk": sdk, "ext": ext}
            for arch, target, sdk, ext in RELEASES
        ]
    }


def expected_packages(version):
    return [f"tollgate-wrt_{version}_{arch}.{ext}" for arch, _, _, ext in RELEASES]


def offline_matrix():
    return {
        "include": [
            {"arch": arch, "target": target, "release": release,
             "profile": profile, "ext": ext}
            for arch, target, release, profile, ext in OFFLINE_BUNDLES
        ]
    }


def expected_offline(version):
    return [
        f"tollgate-wrt-{version}-{arch}-offline.tar.gz"
        for arch, _, _, _, _ in OFFLINE_BUNDLES
    ]


def expected(version):
    """The COMPLETE release asset set: what SHA256SUMS must cover."""
    return expected_packages(version) + expected_offline(version)


def main(argv):
    if len(argv) >= 2 and argv[1] == "matrix":
        json.dump(matrix(), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if len(argv) >= 2 and argv[1] == "offline-matrix":
        json.dump(offline_matrix(), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if len(argv) >= 3 and argv[1] == "expected-packages":
        for name in expected_packages(argv[2]):
            print(name)
        return 0
    if len(argv) >= 3 and argv[1] == "expected-offline":
        for name in expected_offline(argv[2]):
            print(name)
        return 0
    if len(argv) >= 3 and argv[1] == "expected":
        for name in expected(argv[2]):
            print(name)
        return 0
    sys.stderr.write((__doc__ or "") + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
