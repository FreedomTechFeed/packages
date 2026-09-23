#!/usr/bin/env python3
"""Single source of truth for the per-release tollgate-wrt asset set.

Both the release build matrix and the release manifest are derived from the
table below, so the two can never drift apart: adding an arch to RELEASES
extends the matrix AND the expected asset list in the same commit.

Usage:
    release-assets.py matrix              -> GitHub Actions matrix JSON
    release-assets.py expected <version>  -> expected asset names, one per line

<version> is the feed's PKG_VERSION (net/tollgate-wrt/Makefile), e.g.
0.6.0_alpha4_pre15; asset names are

    tollgate-wrt_<version>_<arch>.<ext>
"""
import json
import sys

# (arch, openwrt target, SDK branch, package extension)
#
# Two SDK images are built per arch:
#   master        -> apk-tools package (.apk), OpenWrt 25+
#   openwrt-24.10 -> opkg package (.ipk), OpenWrt <= 24.x
# The wizard selects .apk vs .ipk by the package manager it finds on the router
# (net4sats-wizard-go arch.go / tollgateArchAssets).
RELEASES = [
    ("aarch64_cortex-a53", "mediatek-filogic", "master", "apk"),
    ("aarch64_cortex-a53", "mediatek-filogic", "openwrt-24.10", "ipk"),
    ("aarch64_cortex-a72", "bcm27xx-bcm2711", "master", "apk"),
    ("aarch64_cortex-a72", "bcm27xx-bcm2711", "openwrt-24.10", "ipk"),
    ("arm_cortex-a7", "bcm27xx-bcm2709", "master", "apk"),
    ("arm_cortex-a7", "bcm27xx-bcm2709", "openwrt-24.10", "ipk"),
    ("mipsel_24kc", "mt7621", "master", "apk"),
    ("mipsel_24kc", "mt7621", "openwrt-24.10", "ipk"),
    ("mips_24kc", "ath79-generic", "master", "apk"),
    ("mips_24kc", "ath79-generic", "openwrt-24.10", "ipk"),
    ("mips64_octeonplus", "octeon-generic", "master", "apk"),
    ("mips64_octeonplus", "octeon-generic", "openwrt-24.10", "ipk"),
    ("x86_64", "x86-64", "master", "apk"),
    ("x86_64", "x86-64", "openwrt-24.10", "ipk"),
]


def matrix():
    return {
        "include": [
            {"arch": arch, "target": target, "sdk": sdk, "ext": ext}
            for arch, target, sdk, ext in RELEASES
        ]
    }


def expected(version):
    return [f"tollgate-wrt_{version}_{arch}.{ext}" for arch, _, _, ext in RELEASES]


def main(argv):
    if len(argv) >= 2 and argv[1] == "matrix":
        json.dump(matrix(), sys.stdout)
        sys.stdout.write("\n")
        return 0
    if len(argv) >= 3 and argv[1] == "expected":
        for name in expected(argv[2]):
            print(name)
        return 0
    sys.stderr.write((__doc__ or "") + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
