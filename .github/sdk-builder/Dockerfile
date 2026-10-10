# syntax=docker/dockerfile:1
#
# TollGate SDK builder image.
#
# Base = an EXACT-RELEASED OpenWrt SDK image (tag `<arch>-<version>`), which
# already bundles the extracted SDK at /builder (the image's own setup RUN step
# does the extraction; see openwrt/sdk). This image pre-warms the dependency
# closure of net/tollgate-wrt so a per-PR / per-tag
# `make package/tollgate-wrt/compile` reuses it instead of rebuilding the whole
# closure (measured ~1200 s in the PR lane).
#
# Consumed by openwrt/gh-action-sdk via its (undocumented) CONTAINER build-arg:
# the calling workflow sets
#     CONTAINER: ghcr.io/freedomtechfeed/tollgate-sdk
#     ARCH:      <arch>-<version>
# and gh-action-sdk builds its thin wrapper FROM `$CONTAINER:$ARCH`. Adoption is
# opt-in behind the repo variable TOLLGATE_SDK_IMAGE; until it is set the lanes
# use ghcr.io/openwrt/sdk and behave exactly as before. See docs/fast-builds.md.
#
# VERIFY BEFORE ENABLING: this Dockerfile is a starting implementation and has
# NOT yet been validated by a manual workflow_dispatch run. Build the image,
# inspect it, run one PR lane against it, and compare timings before setting the
# repository variable.
ARG SDK_IMAGE=ghcr.io/openwrt/sdk:aarch64_cortex-a53-25.12.5
FROM ${SDK_IMAGE}

# Base image defaults: USER buildbot, WORKDIR /builder. Keep the user so the
# runtime gh-action-sdk container (which runs as the image user) can write.
# `feed/` is staged into the build context by the calling workflow
# (.github/workflows/build-tollgate-sdk-image.yml).
COPY --chown=buildbot:buildbot feed /builder/feed

# Mirror gh-action-sdk's entrypoint: rewrite the git.openwrt.org feeds to their
# github.com mirrors, add the tollgate feed as a src-link, update feeds,
# generate a default config, install the package, and compile it once so its
# whole closure (Go host toolchain, nodogsplash, jq, ca-bundle, …) is warm.
# Logs/tmp are dropped so the layers stay small; build_dir/staging_dir are kept
# on purpose — they are the cache.
RUN set -eux; \
    sed \
      -e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
      -e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
      -e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
      feeds.conf.default > feeds.conf; \
    echo "src-link tollgate /builder/feed/" >> feeds.conf; \
    ./scripts/feeds update -a; \
    make defconfig; \
    ./scripts/feeds install -f -p tollgate tollgate-wrt; \
    make -j"$(nproc)" package/tollgate-wrt/compile; \
    rm -rf logs tmp
