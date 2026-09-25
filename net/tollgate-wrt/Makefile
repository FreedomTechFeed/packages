# SPDX-License-Identifier: GPL-3.0-only
#
# tollgate-wrt — Cashu-powered WiFi payment gateway for OpenWrt.
#
# Directory holding this recipe, captured BEFORE any include so
# $(MAKEFILE_LIST)'s last word is still this file (rules.mk/package.mk append
# many paths, e.g. the toolchain dir). Used to install the portal/admin
# assets staged into files/ by scripts/build-portal-bundle.sh (build-in-CI) —
# see the install recipe and files/ note below.
PKG_MAKEFILE_DIR:=$(dir $(abspath $(lastword $(MAKEFILE_LIST))))
#
# This feed package downloads the upstream source tarball and builds it with
# golang-package.mk. The upstream repo (tollgate-module-basic-go) is NOT
# modified — its Go source lives under src/ and uses a multi-module layout
# (the main module at src/ plus sibling sub-modules wired via `replace`).
#
# The runtime files (init.d, uci-defaults, nftables.d, hotplug.d, man pages,
# usr/bin helpers, keep.d) are NOT vendored into this feed. They are installed
# directly from the SOURCE TARBALL's packaging/files/ directory (see
# $(PKG_TARBALL_DIR) below), which ships OpenWrt-shaped files because upstream
# releases its own .ipk from the same tree. Bumping PKG_SOURCE_VERSION pulls in
# the matching runtime files automatically.
#
# The captive-portal + admin SPAs are built IN CI (build-in-CI rule, #335): a
# workflow step runs net/tollgate-wrt/scripts/build-portal-bundle.sh, which
# clones OpenTollGate/tollgate-captive-portal-site at the immutable commit
# pinned in vendor.lock.json, runs `npm run build`, and stages the result under
# files/tollgate-captive-portal-site/ and files/tollgate-admin/. The
# gh-action-sdk build mounts the workspace as /feed, so the install recipe below
# sees those staged files and ships them. No built asset is committed to this
# repo. See docs/architecture/portal-bundle-ownership.md for the placement map
# and net/tollgate-wrt/test-devendored.sh for the guard.
#
# Versioning: PKG_VERSION (apk-legal, underscore) names the package version
# while PKG_SOURCE_VERSION (the immutable upstream COMMIT SHA) drives the
# download URL/tarball name and the SHA-named build dirs below — see the
# version block for why they are split.
#
# One package, two binaries:
#   - tollgate-wrt : the service, the module-root main package at src/main.go
#   - tollgate      : the CLI, a SEPARATE module at src/cmd/tollgate-cli/
#
# Because the CLI is its own Go module it cannot share the main module's
# golang-package.mk build context, so Build/Compile builds the service via the
# default helper and then builds the CLI manually from its own module dir,
# reusing the framework's exported cross-compile/toolchain environment.

include $(TOPDIR)/rules.mk

PKG_NAME:=tollgate-wrt
# PKG_VERSION is the apk-legal package version. Since OpenWrt SDKs moved to
# apk (CONFIG_USE_APK, v24.10+), include/package-pack.mk feeds
# "version:$(VERSION)" = "$(PKG_VERSION)-r$(PKG_RELEASE)" to `apk mkpkg`, and
# apk-tools 3.x REJECTS hyphens ("package version is invalid", make Error 99).
# apk pre-release convention uses '_' (or '~'): 0.6.0_alpha2_pre2-r1 is accepted.
#
# '_pre' + counter marks this as a PRE-TAG build of the v0.6.0-alpha2 tree: it
# is the tip of main, built before the tag was cut. The counter distinguishes
# successive main-tip builds of the SAME pre-tag tree: the previous pin
# (089e876) shipped '_pre', this repin of a newer main tip (7cd1882) ships
# '_pre2'. apk orders it strictly ABOVE the build it replaces and strictly
# BELOW the eventual tag build —
#     0.6.0_alpha2_pre < 0.6.0_alpha2_pre2 < 0.6.0_alpha2
# — checked with `apk version -t` (ordering) and `apk version -c` (legality)
# on apk-tools 3.0.5, so a device already running '_pre' is OFFERED this build,
# and is then offered the real alpha2 once it is published. A tester can always
# tell from the installed version which of the three they are running.
# The counter MUST stay glued to the letters: '_pre.2' and '_pre_2' are both
# rejected by apk-tools 3 ("package version is invalid", `apk version -c`
# exit 1). The tag mirror stays derivable by the installer's rule (drop the
# leading 'v', turn '-' into '_'): v0.6.0-alpha2-pre2 -> 0.6.0_alpha2_pre2.
#
# pre4 published a package whose captive portal actually works (vendored
# assets); pre5 added the portal ENTRY cache-bust and the CLI main.version
# injection. pre6 repins to the module commit that carries the cache-bust
# UPSTREAM, so the feed-side 91-tollgate-portal-cachebust workaround is removed
# (one mechanism, not two). pre9 adds the postinst service restart for in-place
# upgrades and repins to the degraded-mode recovery pair (module #420/#421), so
# a mint outage under traffic no longer leaves a router stuck degraded. The
# release-publish workflow names assets by PKG_VERSION, so each change rides a
# NEW version. pre10 hardened 92-tollgate-admin-setup, but its second commit
# (a7ccc509) re-vendored the script back to the pre9 version — pre11 re-vendors
# it from portal-site main (#44, a260172): the board is served over HTTP on
# :8090 (the URL people type; HTTPS-only :8090 made http://<router>:8090/ dead
# on the MT3000), with an OPT-IN HTTPS listener on :8443 when a cert/key pair
# exists — one uhttpd instance cannot serve HTTP and HTTPS on the same port. It
# keeps the brand-deterministic webroot (__ADMIN_HOME__), LuCI-proofing (delete
# cgi/lua_prefix), :8090/:8443 exclusivity, and de-skin. pre11 also repins the
# module (below) to #449 (netifd wireless-status Wi-Fi scan) + #458 (captive-LAN
# access to :8090/:8443). pre12 re-vendors 92 from portal-site main (#45,
# cdd5028) to re-assert the captive-LAN :8090/:8443 users_to_router allow on
# EVERY install: the module's 99-tollgate-setup only applies it on a full setup
# pass, which apk upgrades skip (upstream #459), so an upgrade could leave :8443
# unreachable. pre13 re-vendors the portal + admin bundles (portal-site main
# #47/#48 + #46) and the tollgate rpcd ACL (allowing /tmp/dhcp.leases read so the
# board Devices page works on OpenWrt 25.x), and adds a cert-guarded
# uhttpd.main.redirect_https so LuCI's http://:8080 stops warning about an
# insecure password field. Module pin/hash unchanged.
#
# pre15 repins the module (below) to 42496214 — the MERGED MODULE MAIN TIP, 5
# commits PAST the v0.6.0-alpha4 tag (the tag exists; no alpha4 *release* does)
# — replacing the 170b4bd pin, and moves the portal pin WITH it:
# vendor.lock.json -> portal_commit 51a1429, the revision THAT module commit
# declares in packaging/build-inputs.json (.portal.commit), which carries the
# CU110 captive-portal swap-fee pre-check fix. Module pin and vendored portal
# SOURCE therefore describe one release instead of two; the bundle itself is
# still built in CI from the lock (see below).
#
# pre16 advances the pin again (below) to 2796d96c — module main TIP (0 commits
# behind main; 20 commits past the v0.6.0-alpha4 tag), replacing the pre15
# 42496214 pin. Compared with 42496214 the module pin brings #574 (layered
# /ln-invoice backpressure: a mint 429 must not stop sales, and the flood must
# not reach the mint; supersedes #564), #576 (guest-SSID client isolation),
# #575 (a client that left the network is unbound; supersedes #567), #554 (gate
# the release on the happy-path suite), #558 (record the outcome of a Receive
# that outlived its deadline), #566 (the :8090 admin board is unreachable from
# the guest network), #565 (fail closed when the :8090 board has no root
# credentials), #559 (log hygiene also covers proof secrets), #553 (canonicalise
# the client-supplied mint URL), #548 (resolve the client from the socket,
# refuse the sentinel, stop logging spendable tokens) and the pre15-era
# #543/#544/#545/#542 (portal repin, happy-path suite, gate-close fail-open fix,
# lease-path seam). PKG_SOURCE_TAG is UNCHANGED (v0.6.0-alpha4): the repo-root
# VERSION file is still v0.6.0-alpha4 at 2796d96c, so the base did not move —
# only the commit inside it.
#
# pre17 fixes the install RECIPE, not the pins, and the audit is what decides
# that: the file the package was missing
# (packaging/files/etc/nftables.d/31-admin-board-not-guest-reachable.nft, added
# by module #566) is ALREADY in the pre16 tarball at 2796d96c, so no module
# change was required for pre17. Module pin, PKG_SOURCE_TAG, the portal lock and
# PKG_HASH were therefore all left UNCHANGED from pre16 — PKG_HASH is never
# recomputed without a pin move, and pre18 moves the hash WITH the pin (below). Through pre16 the recipe staged etc/nftables.d/ from an explicit
# two-filename list, so that third fragment shipped upstream and never reached
# the package: the published pre16 APK's /etc/nftables.d/ held only
# 20-nds-enforce.nft and 30-backend-firewall.nft (plus the nodogsplash
# 10-custom-filter-chains.nft and README), and :8090 answered HTTP 200 from a
# br-lan (guest) client on the bench MT3000 — the exact thing #566 was merged to
# prevent, with a green release-publish run saying nothing about it. The recipe
# now stages the WHOLE directory by glob (see the install recipe), and
# net/tollgate-wrt/test-pkg-tarball-parity.sh is the both-directions guard that
# compares the staged set against the tarball's own packaging/files/ tree, so a
# future fragment (or a vanished one) fails a test instead of silently shipping.
#
# pre18 does BOTH things the pre17 hardware acceptance demanded, and nothing
# else: it moves the pin and it fixes the install sequence.
#
# (1) The pin moves to cfbfff5a — module main TIP (0 commits behind main; 27
# commits past the v0.6.0-alpha4 tag), replacing 2796d96c, and PKG_HASH is
# recomputed for it. The hash is not a chore bolted on: it IS the identity of
# what every gate below measures, and test-pkg-tarball-parity.sh Gate A fails a
# pin move whose hash was not recalibrated. Tarball sha256 at cfbfff5a:
# 69e3910a33b75c6221e3b0c62a7d1c76683f88f7c8d0651db8ebe686adb54a47 (codeload,
# PKG_SOURCE_URL below). PKG_SOURCE_TAG stays v0.6.0-alpha4 — the repo-root
# VERSION file at cfbfff5a is still v0.6.0-alpha4 (Gate B re-checks it) — and the
# lock stays the deliberate one-commit-ahead pin described below: the module's
# declared .portal.commit at cfbfff5a is STILL e6fe0e0e, unchanged from
# 2796d96c. The pin carries #579 (nodogsplash reload), #578 (order-aware setup
# marker), #563 (the router happy-path harness this round ran on hardware),
# #561, #572, #539 and #519.
#
# (2) pre17's postinst ran the three uci-defaults scripts and restarted ONLY
# /etc/init.d/tollgate-wrt. Those scripts write config; on an install onto a
# RUNNING router the live firewall/dnsmasq/uhttpd/nodogsplash keep the state
# they loaded at their own start, so the package was installed while the box
# still enforced the previous configuration — measured on the bench MT3000 as
# the four operator symptoms (LuCI served on :8090, icon-colour.png against the
# wrong webroot, no captive-portal redirect chain, IPv6 RAs still advertised)
# that disappeared only after a manual `fw4 reload`. The module's own postinst
# at PKG_SOURCE_VERSION already ran the correct sequence; this feed's recipe was
# the only install path missing it (see the ported block in
# Package/tollgate-wrt/postinst below). No new design, no new dependency: the
# same commands, the same order.
#
# THE LOCK'S PORTAL PIN MOVES ONE COMMIT AHEAD OF THE MODULE'S DECLARED ONE, and
# that is deliberate, not an oversight. vendor.lock.json -> portal_commit
# 4c092e0 carries portal #62 (an empty root password is root administration —
# fail closed on the :8090 board): the rpcd plugin, the rpcd ACL,
# 92-tollgate-admin-setup and the built admin SPA. Those four are exactly the
# artifacts THIS FEED vendors/builds from the portal repo — the rpcd plugin/ACL
# and 92 are committed under files/ and the SPAs are built in CI from the lock —
# so the module-side half of that fix (#565's 99-tollgate-setup and #566's
# 31-admin-board-not-guest-reachable.nft, installed from the module tarball)
# would ship WITHOUT its portal half if the lock stayed where the module points.
# The module at 2796d96c still declares .portal.commit = e6fe0e0e (the commit
# pre15/this round's earlier draft pinned), i.e. the commit immediately BELOW
# 4c092e0 — the module repo must repin for its own tag build to agree. Stated as
# a known divergence so nobody "fixes" the lock back: for this pre-release the
# club artifact deliberately carries BOTH halves of the admin-credential fix.
#
# Read `_pre16`/`_pre17`/`_pre18` honestly: like pre15, the pin sits AFTER the
# v0.6.0-alpha4 tag, so this is a post-tag MAIN-TIP build of the alpha4 line,
# not a build that precedes the tag. The ordering the scheme needs still holds,
# and is why the base moved at pre15 (the feed's tag base has always equalled
# the module VERSION at the pin):
#     0.6.0_alpha2_pre13 < 0.6.0_alpha4_pre15 < 0.6.0_alpha4_pre16 < 0.6.0_alpha4_pre17
#     < 0.6.0_alpha4_pre18 < 0.6.0_alpha4
# checked with the apk-tools 3 oracle (`apk version -c` legality, `apk version -t`
# ordering) on openwrt/rootfs:x86_64-v25.12.4 — see the PR body for the output.
# Consequence, stated rather than hidden: a device already running a published
# `0.6.0_alpha4` build is NOT offered this package (only pre-train devices are),
# by construction — the version string sorts below the tag even though these
# bytes are newer than it.
PKG_VERSION:=0.6.0_alpha4_pre18
# PKG_SOURCE_VERSION is the upstream source pin: an immutable 40-char COMMIT
# SHA, NOT a tag and NOT a branch. A shared community feed must not chase a
# moving branch (hash churn, unreproducible builds, every consumer gets
# untested tip), so we pin the commit. This is the tip of main; main's CHANGELOG
# carries "[v0.6.0-alpha2]". pre6 advances the pin from 373770a to d0cb92f2
# (module #404: the 90-tollgate-captive-portal-symlink cache-bust) so the feed
# no longer needs its own 91-... workaround. pre9 advances the pin to 125f6a0
# (module #421, the runtime-downgrade recovery — with #420, the MarkUnreachable
# callback, already beneath it), replacing the interim 66c1f70 (#410) pin.
# pre11 advances the pin to 170b4bd (module #449: the netifd wireless-status
# Wi-Fi scan that replaces the uci-name iwinfo call; #458: captive-LAN access to
# the admin board on :8090/:8443), replacing the 125f6a0 (#421) pin.
# pre15 advances the pin to 42496214 — module main TIP (0 commits behind main;
# 5 commits past the v0.6.0-alpha4 tag), replacing the 170b4bd (#449/#458) pin.
# .portal.commit at this commit is 51a1429 — the portal pin vendor.lock.json now
# carries. Compared with 170b4bd it adds the #513 nodogsplash / pre-auth :443 /
# private-subnet work, #517's portal repin + shipped-bytes guard, and the CU110
# swap-fee pre-check fix.
# pre16 advances the pin to 2796d96c — module main TIP (0 commits behind main;
# 20 commits past the v0.6.0-alpha4 tag), replacing the pre15 42496214 pin.
# .portal.commit at 2796d96c is STILL e6fe0e0e; the lock is deliberately pinned
# one portal commit AHEAD of it, at 4c092e0 (portal #62, the fail-closed :8090
# admin credential fix), because the FEED — not the module tarball — ships the
# rpcd plugin, the rpcd ACL, 92-tollgate-admin-setup and the built admin SPA.
# See the pre16 block above for the full reasoning.
# pre17 left this pin, PKG_SOURCE_TAG, the portal lock and PKG_HASH UNCHANGED
# from pre16, deliberately: the audit showed the missing nftables fragment was
# already in the 2796d96c tarball, so a module change would have been
# unnecessary churn on a community feed (see the pre17 block above). pre18 MOVES
# the pin and the hash together and leaves PKG_SOURCE_TAG and the portal lock
# alone, for the reasons in the pre18 block above.
# It drives the download URL/tarball name and the SHA-named build dirs below —
# never the package version — so the two can differ legally.
PKG_SOURCE_VERSION:=cfbfff5a9e6aa1de03dda783e9b930d9c36e0bf9
# PKG_SOURCE_TAG names the upstream release this commit belongs to. It is used
# ONLY for the version string baked into the binaries, so a tester sees which
# release the build came from instead of a bare SHA.
# It MUST equal the repo-root VERSION file at PKG_SOURCE_VERSION — upstream's
# own builds substitute exactly that value into 99-tollgate-setup's
# __TOLLGATE_VERSION__ (packaging/Makefile: TOLLGATE_DISPLAY_VERSION) and the
# feed's install recipe substitutes this variable for the same placeholder. The
# 2796d96c pin carries VERSION=v0.6.0-alpha4 — the SAME value the outgoing
# 42496214 pin carried (the 170b4bd pin before it carried v0.6.0-alpha2), each
# verified by extracting the pinned tarball's own VERSION
# (`tar xzf <tarball> -O <dir>/VERSION`) rather than from memory — so pre16
# leaves this variable UNCHANGED, and pre17 re-verified it the same way against
# the SAME pin (test-pkg-tarball-parity.sh Gate B now does that check on every
# run, so it can no longer be a thing someone remembers to do by hand).
# Do not assume that is always so: it moved
# alpha2 -> alpha4 at pre15. A stale tag is a live defect, not a mislabel: it
# writes a setup marker no upstream build writes, and an unchanged marker sends
# an upgrade down 99-tollgate-setup's same-version path where the new full-setup
# work never runs.
PKG_SOURCE_TAG:=v0.6.0-alpha4
# Short SHA for that human-facing version string; the full SHA stays in
# GitCommit, which is what a bug report should quote.
PKG_SOURCE_SHA7:=$(shell printf '%s' $(PKG_SOURCE_VERSION) | cut -c1-7)
# PKG_RELEASE resets to 1 on a PKG_VERSION bump. The captive-portal and admin
# SPAs are built IN CI (scripts/build-portal-bundle.sh) and staged into files/
# for this recipe; upstream gitignores them and only produces them via `npm run
# build`. Without the CI build the package ships splash.html referencing
# /assets/*.js|css that were never built and the portal died with "disallowed
# MIME type (text/html)" / NS_ERROR_CORRUPTED_CONTENT.
PKG_RELEASE:=1

PKG_SOURCE:=tollgate-module-basic-go-$(PKG_SOURCE_VERSION).tar.gz
# The trailing '?' is load-bearing: OpenWrt's scripts/download.pl appends
# "/$(PKG_SOURCE)" to PKG_SOURCE_URL before fetching, so the '?' turns that
# suffix into a query string codeload ignores and leaves the COMMIT SHA as the
# ref. Without it the request would be .../tar.gz/<sha>/<filename> and 404.
# Verified: the exact URL download.pl constructs (with the '?' and the
# PKG_SOURCE suffix) returns this tarball, sha256 == PKG_HASH below.
# Re-calibrated for the 7cd1882 repin: replaying the identical construction for
# the OUTGOING pin (089e876) reproduced the previously committed
# ec27e23cc3f6676bd586b81f12d3be049207206358cadb6ce53d259873111d57 exactly,
# which is what makes the method — and therefore the new hash below — trustworthy.
# pre11 re-calibrated for the 170b4bd pin: the same construction
# (codeload .../tar.gz/<sha>?) yields this tarball, sha256 == PKG_HASH below.
# pre15 re-calibrated the same way for the 42496214 pin: replaying the identical
# construction (curl -fsSL '<PKG_SOURCE_URL>$(PKG_SOURCE)', i.e. the '?' plus the
# PKG_SOURCE suffix) for the OUTGOING pin (170b4bd) reproduced the previously
# committed be7f40a6751420943ae1c547e2aafb74681dedf17839d0b4b6e3c9b4716125dd
# exactly, so the identical construction for 42496214 yielded
# 4b44ee5fefaca57aea7c7acde57a75bad5c4bdb49f67c1fe1a663b4d14a5e119 (the value
# committed through pre15).
# pre16 re-calibrated identically: the SAME construction for the OUTGOING pin
# (a6eb12dc) reproduced that pin's previously committed
# 1027c4f01e4aa755ec02b88eeb7405488776655d5c8e76237036b00a4451c955 exactly, so
# the same construction for 2796d96c yields
# 132ebf00dae70b5820eff571b6f1bb66a22f61755f93647b412674baed44ce8c — the value
# committed below (see the PR body for the recorded command output). Replaying
# the OUTGOING pin is the point: it proves the URL form and the hashing method,
# which a fresh download hashing to *something* would not.
# pre17 does NOT recalibrate: the pin did not move, so the hash cannot change
# (recomputing it would be a no-op dressed up as verification). It was re-derived
# anyway as a control — re-downloading 2796d96c with the construction above
# reproduces 132ebf00… — and test-pkg-tarball-parity.sh Gate A now compares the
# tarball's sha256 against this variable on every run, so a future pin bump that
# forgets to recalibrate fails a test instead of failing the SDK download.
# Note the Makefile carries exactly ONE PKG_SOURCE_URL form. The two plausible
# variants were tried and rejected (command output in the PR body): the same URL
# WITHOUT the '?' requests `.../tar.gz/<sha>/<name>` and 404s, and the tag form
# `.../tar.gz/v0.6.0-alpha4?` resolves 200 but hashes DIFFERENTLY
# (28d63edb…), i.e. it is not the commit tarball this pin builds from.
PKG_SOURCE_URL:=https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=69e3910a33b75c6221e3b0c62a7d1c76683f88f7c8d0651db8ebe686adb54a47

PKG_MAINTAINER:=Felix <felix@tollgate.me>
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE

# PKG_BUILD_DIR points at the tarball's src/ directory: that is where the main
# module's go.mod lives, so golang-package.mk operates on the module root and
# the `replace ./xxx` directives resolve to sibling directories in the tree.
# It stays SHA-named (PKG_SOURCE_VERSION) because a codeload tarball of a
# COMMIT extracts to tollgate-module-basic-go-<full-sha>/ — it must NOT follow
# PKG_VERSION. (A tag-based pin extracted to <repo>-<tag>/ instead; switching
# the pin to a SHA moved this directory name with it, which is why it is
# derived from PKG_SOURCE_VERSION rather than written out.)
PKG_BUILD_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)/src

# PKG_TARBALL_DIR is the tarball extraction root (parent of PKG_BUILD_DIR).
# Build/Prepare extracts the WHOLE upstream tarball there, so packaging/files/
# — the OpenWrt-shaped runtime files — survives as a sibling of src/ and can
# be referenced by the install recipe below. Nothing is vendored into this
# feed; the files ride along with the upstream release tarball. SHA-named for
# the same reason as PKG_BUILD_DIR (see above).
PKG_TARBALL_DIR:=$(BUILD_DIR)/tollgate-module-basic-go-$(PKG_SOURCE_VERSION)

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=github.com/OpenTollGate/tollgate-module-basic-go
# The service is the module-root main package (src/main.go). Building it pulls
# in every sub-module via the main go.mod's replace graph.
GO_PKG_BUILD_PKG:=$(GO_PKG)

# Version injection. src/cli is its own sub-module, so the import path keeps
# the /src segment (matches how upstream's CI injects these values). Version is
# built from PKG_SOURCE_TAG (the release this commit belongs to) plus the short
# COMMIT SHA, so a tester running `tollgate version` sees both the release and
# the exact commit — the SHA alone does not identify the release, and the
# apk-legal PKG_VERSION ("0.6.0_alpha2_pre2") is not what upstream would tag.
# GitCommit carries the full SHA.
GO_PKG_LDFLAGS_X:= \
	$(GO_PKG)/src/cli.Version=$(PKG_SOURCE_TAG)-g$(PKG_SOURCE_SHA7) \
	$(GO_PKG)/src/cli.GitCommit=$(PKG_SOURCE_VERSION) \
	$(GO_PKG)/src/cli.BuildTime=$(SOURCE_DATE_EPOCH)

# NOTE on the golang-package.mk include path:
#   In openwrt/packages the golang helpers live at ../../lang/golang/ relative
#   to a net/ package directory, so we anchor there. (In the standalone
#   src-git feed this line is `include $(TOPDIR)/feeds/packages/lang/golang/
#   golang-package.mk` instead.)
include $(INCLUDE_DIR)/package.mk
include ../../lang/golang/golang-package.mk

define Package/tollgate-wrt
	SECTION:=net
	CATEGORY:=Network
	SUBMENU:=Captive Portals
	TITLE:=TollGate - Cashu-powered WiFi Payment Gateway
	URL:=https://tollgate.me
	DEPENDS:=+nodogsplash +jq $(GO_ARCH_DEPENDS)
endef

define Package/tollgate-wrt/description
	TollGate turns an OpenWrt router into a Cashu-powered payment gateway
	for internet access. Customers pay in sats (time- or data-based); the
	router gates network access via NoDogSplash and sweeps balances to
	configured Lightning addresses.
endef

define Package/tollgate-wrt/conffiles
/etc/tollgate/config.json
/etc/tollgate/install.json
/etc/tollgate/identities.json
/etc/nftables.d/20-nds-enforce.nft
endef

# Deterministic extraction + layout diagnostic. Upstream's go.mod lives in a
# tarball subdirectory (src/), and golang-package.mk expects go.mod at
# $(PKG_BUILD_DIR)/go.mod. Extract to $(BUILD_DIR) so $(PKG_BUILD_DIR) (the
# src/ subdir) is reliably populated, and print the layout so CI logs show
# whether the go.mod-not-found issue is extraction or deeper in golang-build.sh.
#
# NOTE: use `-xf <file>` explicitly, NOT `$(TAR_OPTIONS)`. OpenWrt defines
# TAR_OPTIONS:=-xf -` (read archive from stdin), which only works when the
# archive is piped in. Here the archive is a downloaded file in $(DL_DIR), so
# we must name it directly on the command line.
define Build/Prepare
	mkdir -p $(BUILD_DIR)
	$(TAR) -C $(BUILD_DIR) -xf $(DL_DIR)/$(PKG_SOURCE)
	$(Build/Patch)
	@echo "=== PKG_BUILD_DIR = $(PKG_BUILD_DIR) ==="
	@ls -la $(PKG_BUILD_DIR)
	@test -f $(PKG_BUILD_DIR)/go.mod && echo "go.mod: OK" || { echo "go.mod: MISSING"; exit 1; }
endef

# Build both binaries: the service via the framework helper, then the CLI from
# its separate module directory.
#
# WHY this override is REQUIRED (not stylistic): the CLI is its own Go module
# (`module tollgate-cli`, go.mod at src/cmd/tollgate-cli/go.mod), SEPARATE from
# the main module golang-package.mk operates on. GO_PKG_BUILD_PKG cannot cross
# module boundaries — the framework's Build/Compile runs `go install` inside the
# CURRENT module (src/), so it can only build packages in the main module
# (github.com/OpenTollGate/tollgate-module-basic-go); pointing GO_PKG_BUILD_PKG
# at the CLI's import path would fail. Hence the CLI must be built manually
# from its own module dir, reusing the framework's exported cross-compile
# environment. Upstream PR #125 tried to avoid this by restructuring the Go
# source (src/ -> repo root) but was abandoned (~120 files, never rebased), so
# this override is the supported way to ship both binaries from one package.
#
# Make runs each recipe line in a SEPARATE shell, so the cross-compile
# environment set up by GoPackage/Build/Compile does NOT carry over to the
# second recipe line. We must re-establish it via $(GO_PKG_VARS), which adds
# `go` to PATH and exports GOOS/GOARCH/GOARM/GOMIPS/CGO_ENABLED/CC/GOCACHE/
# GOMODCACHE — exactly what the framework uses. The src/cli -X symbols are
# harmless no-ops for the CLI module (it does not contain them); the CLI's OWN
# version is the main-package `main.version`, so it is injected explicitly
# below (without it, `tollgate --version` reports the "dev" sentinel).
define Build/Compile
	$(call GoPackage/Build/Compile)
	cd $(PKG_BUILD_DIR)/cmd/tollgate-cli && \
		$(GO_PKG_VARS) go build -trimpath \
			-ldflags "$(GO_PKG_LDFLAGS_X:%=-X %) -X main.version=$(PKG_SOURCE_TAG)-g$(PKG_SOURCE_SHA7)" \
			-o $(GO_PKG_BUILD_BIN_DIR)/tollgate-cli .
endef

define Package/tollgate-wrt/preinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT:-}" ] && exit 0

# Record the install timestamp so the captive portal / wizard can show it.
if [ -f /etc/tollgate/install.json ]; then
	CURRENT_TIMESTAMP=$$(date +%s)
	if ! jq ".install_time = $$CURRENT_TIMESTAMP" /etc/tollgate/install.json > /tmp/install.json.tmp; then
		echo "Error: Failed to update install_time using jq" >&2
		exit 1
	fi
	if ! mv /tmp/install.json.tmp /etc/tollgate/install.json; then
		echo "Error: Failed to move temporary file to /etc/tollgate/install.json" >&2
		exit 1
	fi
else
	mkdir -p /etc/tollgate
	CURRENT_TIMESTAMP=$$(date +%s)
	if ! echo "{\"install_time\": $$CURRENT_TIMESTAMP}" > /etc/tollgate/install.json; then
		echo "Error: Failed to create /etc/tollgate/install.json" >&2
		exit 1
	fi
fi

exit 0
endef

define Package/tollgate-wrt/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT:-}" ] && exit 0

# Run the oneshot UCI defaults immediately so an install on a running router
# takes effect without waiting for the next boot, THEN RELOAD THE SERVICES.
#
# The reloads are not belt-and-braces, they are the difference between an
# installed package and an applied one. All three scripts above only WRITE
# config: at boot that is enough, because procd reads the config as it brings
# each service up. On an install onto a RUNNING router it is not — firewall,
# dnsmasq, uhttpd and nodogsplash keep the config they loaded when they started,
# so the box goes on enforcing the previous state. Measured on the bench
# GL-MT3000 (pre17, install without reboot): the admin guard chain was absent
# until a manual `fw4 reload`; :8090 served LuCI (uhttpd.main home=/www) instead
# of the admin board; icon-colour.png resolved against the wrong webroot; the
# nodogsplash redirect chains were missing while 20-nds-enforce.nft still
# rejected; and IPv6 RAs were still advertised because dhcp.lan.ra=disabled was
# never loaded.
#
# This block is a VERBATIM port of the sequence the module's own postinst runs
# (packaging/Makefile at PKG_SOURCE_VERSION, the "Restarting network..." block),
# so the module's build and this feed's package reload the same set in the same
# order. The network restart can take br-lan/br-private down, hence the wait
# before the services that bind to them are reloaded.
wait_for_iface() {
	local iface="$$1" count=0
	while [ $$count -lt 15 ]; do
		[ -d "/sys/class/net/$$iface" ] && return 0
		sleep 1
		count=$$((count + 1))
	done
	echo "Warning: $$iface did not appear within 15 s" >&2
	return 1
}

for script in /etc/uci-defaults/90-tollgate-captive-portal-symlink \
              /etc/uci-defaults/99-tollgate-setup \
              /etc/uci-defaults/92-tollgate-admin-setup; do
	if [ -x "$$script" ]; then
		echo "Running $$script ..."
		"$$script" || echo "Warning: $$script exited with code $$?" >&2
	fi
done

echo "Restarting network..."
/etc/init.d/network restart 2>/dev/null || true
wait_for_iface br-lan
wait_for_iface br-private || echo "Note: br-private not found — this is expected on devices without a private network configured."

echo "Reloading remaining services..."
wifi reload 2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true
/etc/init.d/dnsmasq restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/nodogsplash restart 2>/dev/null || true

if [ -x /etc/init.d/tollgate-wrt ]; then
	# stop/start, not restart: an in-place apk/opkg upgrade must execute the NEW
	# binary, and the daemon has to come up AFTER the reloads above.
	/etc/init.d/tollgate-wrt enable 2>/dev/null || true
	/etc/init.d/tollgate-wrt stop 2>/dev/null || true
	/etc/init.d/tollgate-wrt start 2>/dev/null || true
else
	echo "Warning: /etc/init.d/tollgate-wrt not found, skipping service start" >&2
fi

exit 0
endef

# Runtime files are installed from the upstream source tarball's
# packaging/files/ directory (see PKG_TARBALL_DIR above); the binaries install
# lines use $(GO_PKG_BUILD_BIN_DIR) and stay unchanged.
#
# The captive portal + admin SPAs are staged under this repo's files/ by the
# CI build (scripts/build-portal-bundle.sh, build-in-CI rule #335), so the
# install lines below consume what CI produced. They are NOT vendored/committed.
# There is no welcome.html install line any more: it used to be MODULE-owned and
# shipped from the module source tarball, but the module deleted it at #517 and
# no pin since (pre15's 42496214, nor pre16's / pre17's 2796d96c) carries it —
# see the install recipe below and test-devendored.sh Gate D.
#
# One runtime directory is NOT a hand-kept list: etc/nftables.d/ is staged by
# glob so a module-side fragment cannot be forgotten (pre17 fix — see the
# recipe line and test-pkg-tarball-parity.sh). Every other path here is an
# explicit file, and test-pkg-tarball-parity.sh Gates C/E fail if any of them
# stops resolving in the pinned tarball or if the tarball grows a file outside
# the one documented exclusion (the CI-built portal bundle's tree).
define Package/tollgate-wrt/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/tollgate-module-basic-go $(1)/usr/bin/tollgate-wrt
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/tollgate-cli $(1)/usr/bin/tollgate

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/init.d/tollgate-wrt $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/uci-defaults/90-tollgate-captive-portal-symlink $(1)/etc/uci-defaults/
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/uci-defaults/99-tollgate-setup $(1)/etc/uci-defaults/
	# 99-tollgate-setup ships with a literal __TOLLGATE_VERSION__ placeholder in
	# SETUP_VERSION= and MUST be substituted at install time. Both of upstream's
	# own packaging paths do exactly this (packaging/Makefile substitutes
	# $(TOLLGATE_DISPLAY_VERSION), packaging/local-build-ipk.sh substitutes
	# $PKG_VERSION), and upstream's script only falls back to guessing when the
	# placeholder is still present — a fallback that reads /usr/lib/opkg/status,
	# which does not exist on apk-based (OpenWrt 25.x) systems, so an
	# unsubstituted file would make every router write SETUP_VERSION
	# "unsubstituted" into /etc/tollgate-setup-done. The script re-runs full
	# setup when that marker changes, so a wrong value silently breaks the
	# version-bump re-setup path.
	# The substituted value is the repo-root VERSION file's content
	# (PKG_SOURCE_TAG), matching upstream's own builds so the marker is
	# identical when the real tag build lands.
	$(SED) 's|__TOLLGATE_VERSION__|$(PKG_SOURCE_TAG)|g' $(1)/etc/uci-defaults/99-tollgate-setup

	$(INSTALL_DIR) $(1)/etc/nftables.d
	# Stage the WHOLE module-owned etc/nftables.d/ directory by WILDCARD, never a
	# hand-kept list of filenames. pre16 listed 20-nds-enforce.nft and
	# 30-backend-firewall.nft explicitly, so when the module added
	# 31-admin-board-not-guest-reachable.nft (#566, the :8090 admin board is
	# unreachable from the guest network) the file existed in the source tarball
	# and was simply never staged: the published pre16 package shipped two of
	# the three fragments, and on the bench MT3000 :8090 still answered HTTP 200
	# from a br-lan (guest) client — the exact thing #566 was merged to prevent.
	# Nothing failed: the package built, release-publish went green and
	# SHA256SUMS verified, because a hand-maintained install list has no way to
	# notice a new upstream file.
	#
	# The shell expands the glob when the recipe runs, i.e. AFTER Build/Prepare
	# has populated $(PKG_TARBALL_DIR), so a future fragment ships without a
	# recipe edit. If the directory ever goes missing/empty, install fails on the
	# literal pattern and takes the package build down, so this line can never
	# silently stage nothing.
	#
	# THIS FORM IS DELIBERATE — do not "improve" it into a shell for-loop.
	# The OpenWrt package path expands this install define MORE THAN ONCE, so a
	# shell variable written as $$name reaches the shell already partially eaten.
	# Measured on 2026-09-25 in the multi-arch SDK build for mips64_octeonplus:
	# a loop of the shape "for nft in .../*.nft ; do $(INSTALL_DATA) "$$nft" ...; done"
	# ran as `install -m0644 "ft" …` — $$nft became $nft on the first expansion
	# and then `$n` (empty) + `ft` on the next — and failed the build with
	# `install: cannot stat 'ft': No such file or directory`. The repo's own
	# convention for a loop in an install define is FOUR times the dollars
	# ($$$$$$$${var}, see utils/collectd/Makefile), which is exactly the
	# fragility a wildcard avoids: no shell variable, nothing to mis-expand.
	# test-pkg-tarball-parity.sh Gate H fails if that loop shape comes back.
	# Same shape as the man-page line below, which ships for every release.
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/etc/nftables.d/*.nft $(1)/etc/nftables.d/

	$(INSTALL_DIR) $(1)/usr/share/man/man8
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/man/man8/*.8 $(1)/usr/share/man/man8/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/etc/hotplug.d/iface/95-tollgate-restart $(1)/etc/hotplug.d/iface/

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/bin/check_package_path $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/bin/tollgate-apply-ssl $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/bin/tollgate-remove-ssl $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/local/bin
	$(INSTALL_BIN) $(PKG_TARBALL_DIR)/packaging/files/usr/local/bin/first-login-setup $(1)/usr/local/bin/

	$(INSTALL_DIR) $(1)/etc/tollgate/ecash

	$(INSTALL_DIR) $(1)/etc/tollgate/tollgate-captive-portal-site
	# The guest portal + admin SPAs are staged into files/ by scripts/build-portal-bundle.sh
	# (build-in-CI rule #335) and consumed by the $(CP) below. Nothing else is installed
	# here. This line used to install the module-owned welcome.html from the source
	# tarball, but module #517 DELETED that file (it was stale drift sitting next to a
	# regenerated bundle, and the pinned portal build never emitted it), so at pins >=
	# 42496214 (verified absent at a6eb12dc and 2796d96c too) the tarball does not ship it and an $(INSTALL_DATA) on that path fails the
	# package build outright. The pre-auth entry page is the portal's own splash.html,
	# which 90-tollgate-captive-portal-symlink points nodogsplash at. Do NOT re-add the
	# line and do NOT re-vendor a welcome.html copy: test-devendored.sh Gate D fails if
	# either comes back.
	$(CP) $(PKG_MAKEFILE_DIR)files/tollgate-captive-portal-site/. $(1)/etc/tollgate/tollgate-captive-portal-site/

	# Admin board (Preact SPA) served at the ROOT of the dedicated uhttpd
	# instance on :8090, from its brand webroot (/www/tollgate, or
	# /www/net4sats for net4sats builds); it talks to the tollgate ubus
	# object provided by the rpcd plugin below.
	$(INSTALL_DIR) $(1)/www/tollgate
	$(CP) $(PKG_MAKEFILE_DIR)files/tollgate-admin/. $(1)/www/tollgate/

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) $(PKG_MAKEFILE_DIR)files/rpcd/tollgate $(1)/usr/libexec/rpcd/tollgate

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_CONF) $(PKG_MAKEFILE_DIR)files/rpcd/tollgate_acl.json $(1)/usr/share/rpcd/acl.d/tollgate.json

	$(INSTALL_BIN) $(PKG_MAKEFILE_DIR)files/uci-defaults/92-tollgate-admin-setup $(1)/etc/uci-defaults/
	# Substitute the BRAND webroot into the admin setup script (TollGate build ->
	# /www/tollgate). The script reads __ADMIN_HOME__ and must never guess the
	# brand by directory existence — a TollGate build must not serve a leftover
	# net4sats webroot (and vice versa).
	$(SED) 's|__ADMIN_HOME__|/www/tollgate|g' $(1)/etc/uci-defaults/92-tollgate-admin-setup

	$(INSTALL_DIR) $(1)/etc/crontabs

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/lib/upgrade/keep.d/tollgate $(1)/lib/upgrade/keep.d/
endef

$(eval $(call BuildPackage,tollgate-wrt))
