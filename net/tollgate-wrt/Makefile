# SPDX-License-Identifier: GPL-3.0-only
#
# tollgate-wrt — Cashu-powered WiFi payment gateway for OpenWrt.
#
# Directory holding this recipe, captured BEFORE any include so
# $(MAKEFILE_LIST)'s last word is still this file (rules.mk/package.mk append
# many paths, e.g. the toolchain dir). Used to install the vendored
# captive-portal assets — see the install recipe and files/ note below.
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
# ONE EXCEPTION — the captive portal site IS vendored, under
# files/tollgate-captive-portal-site/. Its built assets/ dir is gitignored
# upstream and only produced by packaging/portal-build.sh (Node/npm), which the
# OpenWrt SDK build cannot run; without vendoring, the package ships splash.html
# with dangling /assets/*.js|css references and the portal never boots. See the
# note above the install recipe for the full rationale.
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
# pre4 exists to publish a package whose captive portal actually works: the
# release-publish workflow names assets by PKG_VERSION, so the portal-asset fix
# must ride a NEW version (a PKG_RELEASE-only bump would emit assets named
# 0.6.0_alpha2_pre3_*, colliding with the already-published pre3 assets). Source
# pin is unchanged (373770a is still module main's tip).
PKG_VERSION:=0.6.0_alpha2_pre4
# PKG_SOURCE_VERSION is the upstream source pin: an immutable 40-char COMMIT
# SHA, NOT a tag and NOT a branch. A shared community feed must not chase a
# moving branch (hash churn, unreproducible builds, every consumer gets
# untested tip), so we pin the commit. This is the tip of main, pinned in
# preparation for the v0.6.0-alpha2 tag, which still has not been cut (upstream
# has only v0.6.0-alpha1) — main's CHANGELOG already carries
# "[v0.6.0-alpha2] - 2026-09-13", so the tip IS the intended alpha2 content.
# This repin moves the tip forward from 089e876 to 7cd1882 (7 upstream commits,
# see `git log 089e876..7cd1882`); the runtime files under packaging/files/ are
# byte-identical between the two, only src/ changed, so the install recipe
# below is unaffected.
# It drives the download URL/tarball name and the SHA-named build dirs below —
# never the package version — so the two can differ legally.
PKG_SOURCE_VERSION:=373770ad1ef99b739b3c2b702943da08ed7a194f
# PKG_SOURCE_TAG names the upstream release this commit belongs to. It is used
# ONLY for the version string baked into the binaries, so a tester sees which
# release the build came from instead of a bare SHA.
PKG_SOURCE_TAG:=v0.6.0-alpha2
# Short SHA for that human-facing version string; the full SHA stays in
# GitCommit, which is what a bug report should quote.
PKG_SOURCE_SHA7:=$(shell printf '%s' $(PKG_SOURCE_VERSION) | cut -c1-7)
# PKG_RELEASE resets to 1 on a PKG_VERSION bump. The captive-portal assets are
# vendored (see the files/ note above the install recipe): upstream gitignores
# them and only builds them in CI, so without vendoring the package shipped
# splash.html referencing /assets/*.js|css that were never built and the portal
# died with "disallowed MIME type (text/html)" / NS_ERROR_CORRUPTED_CONTENT.
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
PKG_SOURCE_URL:=https://codeload.github.com/OpenTollGate/tollgate-module-basic-go/tar.gz/$(PKG_SOURCE_VERSION)?
PKG_HASH:=fe1f118beea4113ae8addf85510a419a6da3327f4eba7447a2de114e1a207ac6

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
# GOMODCACHE — exactly what the framework uses. The -X ldflags are harmless
# no-ops for the CLI module (it does not contain those symbols).
define Build/Compile
	$(call GoPackage/Build/Compile)
	cd $(PKG_BUILD_DIR)/cmd/tollgate-cli && \
		$(GO_PKG_VARS) go build -trimpath \
			-ldflags "$(GO_PKG_LDFLAGS_X:%=-X %)" \
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
# takes effect without waiting for the next boot, then enable the service.
for script in /etc/uci-defaults/90-tollgate-captive-portal-symlink \
              /etc/uci-defaults/99-tollgate-setup; do
	if [ -x "$$script" ]; then
		"$$script" || echo "Warning: $$script exited with code $$?" >&2
	fi
done

if [ -x /etc/init.d/tollgate-wrt ]; then
	/etc/init.d/tollgate-wrt enable 2>/dev/null || true
fi

exit 0
endef

# Runtime files are installed from the upstream source tarball's
# packaging/files/ directory (see PKG_TARBALL_DIR above); the binaries install
# lines use $(GO_PKG_BUILD_BIN_DIR) and stay unchanged.
#
# EXCEPTION — the captive portal site is VENDORED from this feed's files/
# directory. The upstream repo gitignores packaging/files/tollgate-captive-
# portal-site/assets/ (commit "build portal assets from source, stop
# committing minified JS") and only produces it at package time via
# packaging/portal-build.sh (Node/npm + the tollgate-captive-portal-site
# repo). The OpenWrt SDK build this feed uses has no npm step, so the tarball
# ships splash.html with hashed /assets/*.js|css references but none of the
# bundles — the portal SPA then fails with "disallowed MIME type (text/html)"
# (uhttpd answers the missing files with its HTML 404 page) and never boots.
# The prebuilt, self-consistent bundle (HTML + assets from the same portal
# commit, plus the module-only welcome.html) is committed under
# files/tollgate-captive-portal-site/ and installed here instead of the
# tarball copy.
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
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/etc/nftables.d/20-nds-enforce.nft $(1)/etc/nftables.d/
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/etc/nftables.d/30-backend-firewall.nft $(1)/etc/nftables.d/

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
	$(CP) $(PKG_MAKEFILE_DIR)files/tollgate-captive-portal-site/. $(1)/etc/tollgate/tollgate-captive-portal-site/

	$(INSTALL_DIR) $(1)/etc/crontabs

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/lib/upgrade/keep.d/tollgate $(1)/lib/upgrade/keep.d/
endef

$(eval $(call BuildPackage,tollgate-wrt))
