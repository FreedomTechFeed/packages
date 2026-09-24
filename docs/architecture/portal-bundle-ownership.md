# Portal bundle placement map (build-in-CI, #335)

**Status:** adopted · **Date:** 2026-09-22 · **Board:** tollgate-module-basic-go (SHIP-W4)

## The rule

> **#335 — build in CI with an artifact, never commit built assets in-tree.**
> The feed CONSUMES an artifact; it does not own portal source.

This ADR is the placement map: for every file the feed's `net/tollgate-wrt`
touches, it states the owning repo and why, with the file-level evidence. The
built SPAs are de-vendored; the vendored *source* files stay.

## Why de-vending the built assets

A hand-committed built bundle is a #335 violation **and** a reproducibility
hazard. The pre-vendor design committed minified JS/CSS under
`net/tollgate-wrt/files/` by hand, which is exactly how the **pre10 admin
regression** (a stale vendored copy) shipped, and it produced the
pre7/pre8/pre10/pre11/pre12/pre13/pre15/pre16 bundle churn. Upstream the module repo
gitignores `packaging/files/tollgate-captive-portal-site/assets/` (commit
"build portal assets from source, stop committing minified JS") — the repo
itself declares these are build output and must never be tracked.

## The single source of truth

`net/tollgate-wrt/vendor.lock.json` pins **one** immutable portal commit (now
the full 40-char SHA `4c092e086f6bf0643851693aa6956351a6fb4036` = portal #62,
"an empty root password is root administration — fail closed on the :8090
board"). It is the authoritative pin for exactly what the package ships: the
guest portal SPA, the admin board, the rpcd plugin, the rpcd ACL and
`92-tollgate-admin-setup`. One release, not two — the module pin and the
vendored portal pin move together in one commit.

**Deliberate divergence at pre16 (recorded, not an oversight).** The normal rule
is that the lock FOLLOWS the module: the pinned module commit names its portal
revision in `packaging/build-inputs.json` → `.portal.commit`. At the pre16
module pin `2796d96c` that value is **still `e6fe0e0e`** — the commit
immediately *below* `4c092e0` — and the module repo must repin for its own tag
build to agree. The feed re-pins AHEAD of the module here on purpose: the rpcd
plugin, the rpcd ACL and `92-tollgate-admin-setup` are vendored into this feed
and the admin SPA is built in CI from the lock, so the module-side half of the
admin-credential fix (module #565's `99-tollgate-setup` and #566's
`31-admin-board-not-guest-reachable.nft`, both installed from the module
tarball) would ship WITHOUT its portal half if the lock stayed at `e6fe0e0e`.
For this pre-release the artifact therefore carries BOTH halves. Unwind the
divergence by re-pinning once the module declares `4c092e0` (or later). (The
outgoing pre15 pin was module `42496214` / portal `51a1429`.)

`npm run build` at that pin (the portal repo's `scripts/build-all.mjs`) emits
`build/` (React guest portal + balance page) and `build/admin/` (Preact admin
board). For the pre16 pin the evidence is the builder's own byte-verification:
`build-portal-bundle.sh` re-clones and rebuilds at the pin and the staged tree
matches `vendor.lock.json` on all 27 entries
(`verified staged file(s) against vendor.lock.json`, exit 0). That was reproduced
independently under BOTH toolchains CI can resolve — node 22.17.0 / npm 10.9.2
(the module's `packaging/build-inputs.json` pin) and node 22.22.1 / npm 9.2.0
(the host's, closest to what `setup-node` `node-version: '22'` fetches) — both
produced byte-identical hashes (27 checked / 0 mismatches), so the *floating*
`'22'` in the workflows is not a byte-identity risk for this lock.
The earlier pre13 harness result is retained below for history:
- `diff -r <rebuild>/build net/tollgate-wrt/files/tollgate-captive-portal-site`
  (excl. `admin/`, `welcome.html`, `logo{192,512}.png`) → identical except the
  module-owned `welcome.html`, which the portal build never emits.
- `diff -r <rebuild>/build/admin net/tollgate-wrt/files/tollgate-admin` →
  byte-identical.

## Placement map

### Built SPAs — OWNER: `OpenTollGate/tollgate-captive-portal-site` → built in FEED CI

| feed dir | contents | WHY it must not be committed here |
|---|---|---|
| `files/tollgate-captive-portal-site/` | guest portal SPA (`splash.html` + hashed `assets/*.js\|css`, `asset-manifest.json`, `404.html`, `balance.html`, `favicon.ico`, `logo*.png`, `manifest.json`, `locales/en.json`) | **build output** — vite production build of the portal repo. The main bundle (`index-YkGiQMp2.js`, 361,920 B at the pre16 pin) is minified JS with a content hash. The portal repo gitignores them; they exist only after `npm run build`. |
| `files/tollgate-admin/` | admin Preact board (`index.html`, `manifest.json`, `assets/*.js\|css`, `assets/brand/**`) | **build output** — `vite build --config admin/vite.config.mjs`. Same reasoning. |

**Collapsed duplicate:** where a byte-identical built file appeared in both the
feed and the module's `packaging/files/tollgate-captive-portal-site/`
(e.g. `splash.html`), ownership collapses to **one producer**: the portal
`npm run build` at the pin. The feed never carries a second copy.

**Mechanism (build-in-CI, not fetch-an-artifact-at-build-time):** a workflow step
runs `net/tollgate-wrt/scripts/build-portal-bundle.sh`, which clones the portal
repo at the pinned commit, runs `npm ci && npm run build`, stages
`build/*`→`files/tollgate-captive-portal-site/` and
`build/admin/*`→`files/tollgate-admin/`, and **byte-verifies the staged tree
against `vendor.lock.json`** (fail-loud). The `gh-action-sdk` build mounts the
workspace as `/feed`, so the Makefile's `$(CP) $(PKG_MAKEFILE_DIR)files/...`
install lines consume exactly what CI staged. No SDK step reaches a second
repository (keeps the offline-build contract).

### `welcome.html` — REMOVED at the pre15 pin (still absent at pre16)

`welcome.html` was **never** produced by the portal build. Through pre13 the
module owned it (`packaging/files/tollgate-captive-portal-site/welcome.html`)
and the feed installed it **from the module source tarball**:
`$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/tollgate-captive-portal-site/welcome.html ...`.

The pinned module commit `42496214` **deletes** that file (module #517: the
pinned portal build never emitted it, so the checked-in copy was stale drift
sitting next to a regenerated bundle), and nothing in the module or in the portal
references it any more — the pre-auth entry page is the portal's own
`splash.html`, which `90-tollgate-captive-portal-symlink` points nodogsplash at.
So pre15 **drops the install line**: `$(INSTALL_DATA)` on a path the pin does not
ship fails the package build outright (confirmed by
`scripts/check-pkg-tarball-paths.sh`: `welcome.html` is the single MISSING path
of 13 `$(PKG_TARBALL_DIR)` references at `42496214`, and resolves fine at
`170b4bd`). The pre16 pin `2796d96c` keeps it deleted: the same check reports
**12 of 12 resolve, 0 missing** at that pin. The file must not be re-vendored into
the feed either — that would be
the same second-hand-copy class as the pre10 admin regression. Gate D below
enforces both halves.

### Vendored SOURCE files — OWNER: `OpenTollGate/tollgate-captive-portal-site`, still vendored as source

These are **not** build output — they are tracked source in the portal repo, so
vendoring them (with a drift guard) is the correct pattern, not a #335
violation. They remain committed under `files/` and the guard byte-compares them
against the **pinned release commit** (`vendor.lock.json` → `portal_commit`), not
portal `main` — see "What the drift guard now does" below.

| feed file | portal source | status |
|---|---|---|
| `files/uci-defaults/92-tollgate-admin-setup` | `packaging/files/etc/uci-defaults/92-tollgate-admin-setup` | **VENDORED SOURCE, CHANGED this round:** `b0086f65…` (12052 B) at `4c092e0`, vs `ebe1332f…` (8937 B) at the outgoing `e6fe0e0e`. See the portal-#62 note under this table. |
| `files/rpcd/tollgate` (exec sh) | `openwrt/rpcd/tollgate` | **VENDORED SOURCE, CHANGED this round:** `91574722…` (7741 B) at `4c092e0`, vs `05852546…` (4116 B) at `e6fe0e0e`. See the portal-#62 note under this table. |
| `files/rpcd/tollgate_acl.json` | `openwrt/rpcd/tollgate_acl.json` | **VENDORED SOURCE, CHANGED this round:** `7c1637be…` (2017 B) at `4c092e0`, vs `14ffed79…` (1367 B) at `e6fe0e0e`. See the portal-#62 note under this table. Locked in `vendor.lock.json`; the builder SKIPS this entry (tracked source, not a build output), so it was proven separately against the pin's own `openwrt/rpcd/tollgate_acl.json`. |

**The portal-#62 note (why all three vendored files moved this round, the first
preN round in which that is true).** Portal #62 is "an empty root password is
root administration — fail closed on the :8090 board". Its premise: rpcd's own
login check returns true while root's `/etc/shadow` hash is unset, so the admin
session on :8090 accepts any passphrase and then carries this plugin's ACL
(file, system.password_set, wallet_drain_cashu). The plugin therefore exposes a
pre-auth `auth_status` probe — the credential STATE only, one of
empty/locked/set/unknown, never a hash — which the ACL grants to the
uauthenticated group so the board can refuse to render a login form before it
has a session, and it refuses every router-acting method with the
`no-admin-credential` error while root has no usable hash. The setup script
checks the same state instead of arming the board anyway. Ordering still
enforced: portal merges first, then the feed re-pins (pin bump + re-vendor from
the SAME commit, atomic).

### Runtime files — OWNER: `OpenTollGate/tollgate-module-basic-go` (module, via tarball)

init.d, uci-99, nftables.d, hotplug.d, usr/bin helpers, keep.d are installed from
`$(PKG_TARBALL_DIR)/packaging/files/…` — never vendored. **The mechanism was
right but the pre16 recipe was wrong about one directory:** `etc/nftables.d/` was
staged from an explicit two-filename list, so
`31-admin-board-not-guest-reachable.nft` (module #566) sat in the tarball and
never reached the package — see the pre17 section at the end of this document.
`etc/nftables.d/` is now staged by **glob** (whole directory: stage the directory,
never a list), and `net/tollgate-wrt/test-pkg-tarball-parity.sh` compares the
staged set against the tarball's own `packaging/files/` tree in **both**
directions. Do not "tidy" that back into a file list.

## What the drift guard now does (honest)

`vendor-drift.yml`:
- **source-drift** — byte-compares the three vendored portal-owned files
  (`92-tollgate-admin-setup`, `rpcd/tollgate`, `rpcd/tollgate_acl.json`) against
  the **pinned release commit** in `vendor.lock.json` → `portal_commit` — the same
  SHA `build-portal-bundle.sh` stages from and the module releases against.
  **It no longer compares to portal `main`.** Comparing to a moving branch made
  the guard red on every unrelated portal commit, which forced ad-hoc byte-copying
  and let the shipped `92` diverge from the package's own pin — the pre10 admin
  regression class. A red guard now means *"this release's pin is not synced"*,
  which is actionable, instead of *"upstream moved"*. (Override for an ad-hoc
  check: `PORTAL_REF=<sha> sh .github/scripts/check-vendor-drift.sh`.)
- **bundle-rebuild** — runs `scripts/build-portal-bundle.sh` (the same builder
  the SDK uses) and byte-verifies the staged bundle against `vendor.lock.json`.
  The old `bundle-lock` job and `vendor_lock.py` are gone: there is no committed
  tree to lock against anymore, the staged tree IS the lock check.

## CI-enforced ordering (do not invert)

1. **Portal merges FIRST,** then the feed re-pins — the lock's `portal_commit`
   and the vendored `92`/rpcd copies move **together in one commit**, taken from
   that same SHA. If the feed's vendored copy does not equal its own pin,
   `source-drift` fails.
2. `#335` is now mechanically enforced: `test-devendored.sh` Gate A fails if any
   built bundle file is re-committed under `files/`; Gate B fails if the CI
   wiring (or its ngit lane) stops producing the bundle; Gate C fails if the pin
   drifts from a full immutable SHA; Gate D fails if the module-owned
   `welcome.html` the pre15 pin deleted (and pre16 still does not ship) comes back — as a `$(PKG_TARBALL_DIR)`
   install line (a build break at this pin) or as a re-vendored copy under
   `files/`.
3. **Module-tarball parity is mechanically enforced** (pre17, after the pre16
   defect below): `net/tollgate-wrt/test-pkg-tarball-parity.sh` fails if any
   `$(PKG_TARBALL_DIR)` install reference stops resolving in the pinned tarball,
   or if the tarball ships a `packaging/files/` file the recipe never stages —
   with `etc/nftables.d/` compared as an exact set, no exclusions. It runs on
   PR + push (`.github/workflows/pkg-tarball-parity.yml`) and locally.

## Test evidence (run 2026-09-22)

- RED: `sh net/tollgate-wrt/test-devendored.sh` → exit 1 (Gates A–D fail on master).
- GREEN: after the fix → exit 0.
- Byte-identity of staged bundle vs committed pre-fix bundle: `diff -r` clean
  (except module-owned `welcome.html`).
- `build-portal-bundle.sh` end-to-end: `portal=… @ 4f74a6dd5a…` staged 18 guest
  + 12 admin files, verified against `vendor.lock.json`, exit 0.

### pre15 re-pin (module `42496214`, portal `51a1429`) — run 2026-09-23

- Run 1 of `build-portal-bundle.sh` (lock's `files` map still the outgoing
  pin's) staged 18 guest + 8 admin files and exited 1 with 14 DRIFT lines —
  expected: the lock is the old pin's manifest, and the portal's JS changed (the
  CU110 swap-fee pre-check fix), so the map is not a no-op.
- Re-locked the `files` map from the staged tree (old slot order preserved):
  **27 entries, unchanged count**; 5 content-hashed asset names rotate →
  `qr-scanner.min-BDydjDes.js`, `index-BDGoMmEt.js`, `portal-vvGVzSiy.js`,
  `balance-BIRYjkHz.js`, `browser-ponyfill-C89IJYgT.js`; 4 same-name hash
  rotations → `asset-manifest.json`, `balance.html`, `splash.html`,
  `locales/en.json`. The **admin board is byte-identical** at both pins.
- Run 2 (independent clone+build) printed
  `build-portal-bundle: verified staged file(s) against vendor.lock.json` /
  `OK (OpenTollGate/tollgate-captive-portal-site@51a1429bb3b5e3b41eb1001bfa612543ba1fcd1a)`,
  exit 0 — the re-lock reproduces. Re-deriving the map from the staged tree is
  idempotent (byte-identical to the committed map).
- Toolchain independence: the same build under node 22.22.1 / npm 9.2.0
  produced the same 27/27 hashes as node 22.17.0 / npm 10.9.2.
- Tracked sources: all three (`92-tollgate-admin-setup` `ebe1332f…` /
  `rpcd/tollgate` `05852546…` / `rpcd/tollgate_acl.json` `14ffed79…`) are
  **identical at BOTH pins** — so this round re-pinned them without changing
  bytes, which is the honest statement; there was no byte change to re-vendor.
- `sh net/tollgate-wrt/test-devendored.sh` → exit 0 (Gates A–E; Gate D in its
  new inverted "the deleted welcome.html must stay deleted" form).
- `sh net/tollgate-wrt/test-feed-ci.sh` → exit 0
  (`PKG_VERSION=0.6.0_alpha4_pre15`).
- `sh .github/scripts/check-vendor-drift.sh` → exit 0 (`vendored 92 + rpcd
  (plugin, ACL) match …@51a1429bb3b5e3b41eb1001bfa612543ba1fcd1a`).
- Buildability of every tarball path the recipe installs: all **12**
  remaining `$(PKG_TARBALL_DIR)/…` references resolve inside the `42496214`
  tarball (0 missing) once the dead `welcome.html` line is dropped. The same
  check is what exposed the break — `welcome.html` exists at `170b4bd` and is
  absent from `42496214`.
- Not run here: the gh-action-sdk multi-arch build (needs an OpenWrt SDK); CI
  runs it, and the CI bundle step is the same `build-portal-bundle.sh` verified
  above.

### pre16 re-pin, revision 2 (module `2796d96c`, portal `4c092e0`, version `0.6.0_alpha4_pre16`) — run 2026-09-24

The round's FIRST draft (module `a6eb12dc` / portal `e6fe0e0e`) never left the
branch — no tag, no release — and is superseded in place, so there is one pre16.

- Run 1 of `build-portal-bundle.sh` (lock moved to `4c092e0`, the `files` map
  still the outgoing pin's) staged 18 guest + 8 admin files and exited 1 with
  **3 DRIFT lines** — expected, and evidence the pin changes bytes: the admin
  board rotated `assets/index-DJpT8hFU.js` → `assets/index-CKy1kEGj.js` (plus
  `index.html`). The guest portal is byte-identical at both pins, because portal
  #62 touched only `admin/`, `openwrt/rpcd/` and `packaging/`.
- Re-locked the `files` map from the staged tree (old slot order preserved):
  **27 entries, unchanged count**; 1 content-hash rename + 1 same-name rotation,
  both in the admin board. **Method calibration:** rebuilding the OUTGOING pin
  (`e6fe0e0e`) reproduced its committed lock byte-for-byte — the rebuilt
  `build/admin/assets/index-DJpT8hFU.js` hashes to `d1c185d4…`, exactly the value
  the outgoing lock carried for it — so the map is produced by the same builder
  the lock was locked from, not by a different toolchain.
- Run 2 (independent clone + build) printed
  `build-portal-bundle: verified staged file(s) against vendor.lock.json` /
  `OK (OpenTollGate/tollgate-captive-portal-site@4c092e086f6bf0643851693aa6956351a6fb4036)`,
  exit 0 — the re-lock reproduces, and re-deriving the map is idempotent.
- Toolchain independence: the same build under node 22.17.0 / npm 10.9.2 (the
  module's `packaging/build-inputs.json` pin) and under node 22.22.1 / npm 9.2.0
  (the host's) both verified **27/27** against the committed lock, and an
  independent hash sweep of every lock entry against the staged tree reported
  `27 checked / 0 mismatches`.
- **CHANGED bytes this round: all three vendored SOURCE files differ from the
  outgoing pin** (the first preN round in which that is true): `rpcd/tollgate`
  `05852546…` → `91574722…` (7741 B), `rpcd/tollgate_acl.json` `14ffed79…` →
  `7c1637be…` (2017 B), `92-tollgate-admin-setup` `ebe1332f…` → `b0086f65…`
  (12052 B). Each was downloaded from `raw.githubusercontent.com` at `4c092e0`,
  byte-compared (`cmp`) against the feed copy and only then replaced — never
  through `gh api … --jq .content | base64 -d`, whose command substitution strips
  trailing newlines and makes every file read as DIFFERS. The added/removed line
  counts match portal #62's own diff exactly (+83/-0, +9/-0, +75/-9).
- **Decisive check — the staged bytes carry the fix the pin claims, and the check
  DISCRIMINATES.** New markers from portal #62, `grep -rl` on the staged tree:
  `no-admin-credential` and `credential_usable` in `files/rpcd/tollgate`;
  `auth_status` in `files/rpcd/tollgate`, `files/rpcd/tollgate_acl.json` and the
  built `files/tollgate-admin/assets/index-CKy1kEGj.js`; `root_hash_state` in
  both the plugin and `files/uci-defaults/92-tollgate-admin-setup`. Negative
  control: the same greps are ABSENT on the outgoing pin — the three files
  fetched from `e6fe0e0e`, and a fresh `npm run build` of `e6fe0e0e` in a scratch
  clone (whose admin bundle contains no `auth_status` and emits the OLD filename
  `index-DJpT8hFU.js`). A green that never went red proves nothing; this one went
  red on the outgoing pin.
- `sh net/tollgate-wrt/test-devendored.sh` → exit 0 (Gates A–E; Gate C now
  reports the immutable portal SHA `4c092e08…`).
- `sh net/tollgate-wrt/test-feed-ci.sh` → exit 0 (`PKG_VERSION=0.6.0_alpha4_pre16`).
- `sh .github/scripts/check-vendor-drift.sh` → exit 0: `OK: vendored 92 + rpcd
  (plugin, ACL) match OpenTollGate/tollgate-captive-portal-site@4c092e086f6bf0643851693aa6956351a6fb4036`.
- `scripts/check-pkg-tarball-paths.sh net/tollgate-wrt/Makefile <2796d96c tree>`
  → `OK: all 12 $(PKG_TARBALL_DIR) reference(s) resolve inside the pin's
  tarball` (0 missing; `welcome.html` stays deleted). Tarball member diff
  outgoing → new pin: **0 removed, 20 added** (e.g.
  `packaging/files/etc/nftables.d/31-admin-board-not-guest-reachable.nft`,
  `tests/packaging/admin-board-requires-credential_test.sh`), so no install line
  lost its file.
- `PKG_HASH` calibrated the same way as every round: the identical URL
  construction for the OUTGOING pin `a6eb12dc` reproduced its committed
  `1027c4f0…` exactly, so the same construction for `2796d96c` yields
  `132ebf00…`. Both plausible variants re-tested at the new pin: the same URL
  without the trailing `?` → HTTP **404**; the tag form
  `…/tar.gz/v0.6.0-alpha4?` → `28d63edb…`, a different tree.
- `apk version -c` / `apk version -t` on `openwrt/rootfs:x86_64-v25.12.4`:
  `0.6.0_alpha4_pre16` is VALID, and
  `0.6.0_alpha2_pre13 < 0.6.0_alpha4_pre15 < 0.6.0_alpha4_pre16 < 0.6.0_alpha4`.
- Not run here: the gh-action-sdk multi-arch build (it needs an OpenWrt SDK); CI
  runs it, and the CI bundle step is the same `build-portal-bundle.sh` verified
  above.

### pre17 — the install RECIPE was the defect (module `2796d96c`, portal `4c092e0`, version `0.6.0_alpha4_pre17`) — run 2026-09-25

Pins did not move this round: module `2796d96c`, `.portal.commit`/`vendor.lock.json`
`4c092e0`, `PKG_SOURCE_TAG` `v0.6.0-alpha4` and `PKG_HASH` are all the pre16 values,
and the locked bundle map is untouched. The fix is entirely in the feed's install
recipe, and it is the reason the pins did not need to move.

**The defect, measured on the published artifact (not read from the recipe).**
`apk extract` of the published
`tollgate-wrt_0.6.0_alpha4_pre16_aarch64_cortex-a53.apk` (8,361,504 B, sha256
verified against the release `SHA256SUMS`) shows `/etc/nftables.d/` holding exactly
`20-nds-enforce.nft` and `30-backend-firewall.nft`; `apk manifest` agrees — 87
entries, 2 of them under `etc/nftables.d/`. On the bench MT3000 the directory also
carried `10-custom-filter-chains.nft` and `README`, both owned by the **nodogsplash**
package, not by us. `31-admin-board-not-guest-reachable.nft` — module #566, merged,
the fragment that makes the `:8090` admin board unreachable from the guest network —
was simply never in the package, so `:8090` answered HTTP 200 from a br-lan (guest)
client. `release-publish.yml` was green: it reports on the asset set, not on a
file list.

**The audit (pin `2796d96c`, tarball `packaging/files/` = 62 files).** Every
`$(PKG_TARBALL_DIR)` reference in `Package/tollgate-wrt/install` was resolved
against the extracted tarball and compared, as a set, with the tarball's own tree:

| dir | module files | staged at pre16 | staged at pre17 | mechanism |
|---|---|---|---|---|
| `etc/nftables.d/` | 3 | **2** | 3 | `$(PKG_TARBALL_DIR)` **glob** (was an explicit 2-filename list) |
| `man/man8/` | 41 | 41 | 41 | `$(PKG_TARBALL_DIR)` glob `*.8` |
| `etc/init.d/` | 1 | 1 | 1 | explicit `$(INSTALL_BIN)` |
| `etc/uci-defaults/` | 2 | 2 | 2 | explicit + `$(SED)` version/brand substitution |
| `etc/hotplug.d/iface/` | 1 | 1 | 1 | explicit |
| `usr/bin/` | 3 | 3 | 3 | explicit |
| `usr/local/bin/` | 1 | 1 | 1 | explicit |
| `lib/upgrade/keep.d/` | 1 | 1 | 1 | explicit |
| `tollgate-captive-portal-site/` | 9 | 0 | 0 | **deliberate**: the guest portal is built in CI from `vendor.lock.json` → `portal_commit`; the module's copy is asset-less and would be a second, older portal (the pre10 admin-regression class) |
| **total** | **62** | **52** | **53** | |

So the complete set of module files the pre16 package did not ship was exactly two
groups: the one real miss (`etc/nftables.d/31-admin-board-not-guest-reachable.nft`)
and the nine-file portal duplicate that is excluded by design. **The module tarball
already carried the guard file, which is why no module change was required** — the
feed's own enumeration was the whole bug. No `$(PKG_TARBALL_DIR)` reference was
missing from the tarball (12/12 resolved, 0 missing; 11 after the rewrite, because
two explicit nft lines became one glob).

**The change.** The two explicit `nftables.d` install lines are replaced by ONE
wildcard line over the whole directory — the same shape as the man-page line just
below it:

```make
$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/etc/nftables.d/*.nft $(1)/etc/nftables.d/
```

A future fragment needs no recipe edit; if the directory ever goes missing or
empty, `install` fails on the literal pattern and takes the build down, so the line
cannot silently stage nothing. Nothing else in the recipe changed; no file was
renamed; the portal bundle and its pin are untouched.

**Why not a shell for-loop — measured, not theorised.** The first form of this fix
was a loop:

```make
for nft in $(PKG_TARBALL_DIR)/…/etc/nftables.d/*.nft; do \
	$(INSTALL_DATA) "$$nft" $(1)/etc/nftables.d/ || exit 1; \
done
```

It passes every local check (a plain `make` harness runs it correctly) and **fails
the real SDK build.** In the `multi-arch-test-build.yml` run for PR #27 the
`mips64_octeonplus` job's log shows the executed command as

```
for nft in /builder/build_dir/…/packaging/files/etc/nftables.d/*.nft; do install -m0644 "ft" /builder/build_dir/…/tollgate-wrt/etc/nftables.d/ || exit 1; done
install: cannot stat 'ft': No such file or directory
make[2]: *** [Makefile:625: …/tollgate-wrt-0.6.0_alpha4_pre17-r1.apk] Error 1
```

`$$nft` had become `$nft` before the shell got it, and then `$n` (empty) + `ft`. The
OpenWrt package path expands the install define **more than once** — this repo's own
loop idiom is `$$$$$$$${var}`, four times the dollars (`utils/collectd/Makefile`),
i.e. four collapses — and the count is path-dependent (ipk vs apk). That is exactly
why the fix carries **no shell variable at all**: text with zero `$name` references
is identical under any number of expansions. A local single-expansion harness would
never have caught this, and neither would the parity test — so the parity test now
has **Gate H**, which fails on `$$name` inside the install define (and deliberately
does not fire on the legitimate four-dollar idiom).

**The guard.** `net/tollgate-wrt/test-pkg-tarball-parity.sh` (both directions,
`etc/nftables.d/` compared as an exact set with **no** exclusions):
- Gate A — the tarball's sha256 == `PKG_HASH`, and it extracts
- Gate B — the tarball's own `VERSION` == `PKG_SOURCE_TAG` (the Makefile's documented invariant, now checked mechanically on every run instead of by hand)
- Gate C — **missing direction**: every `$(PKG_TARBALL_DIR)` install reference resolves inside the tarball
- Gate D — **extra direction**, `etc/nftables.d/`: exact set equality, no exclusions
- Gate E — **extra direction**, whole tree: every `packaging/files/` file outside the one documented exclusion must be staged
- Gate F — the exclusion is not a hole: every excluded file needs a `vendor.lock.json` counterpart
- Gate G — the exclusion must never be widened over a guarded directory
- Gate H — the install recipe carries no `$$name` shell-variable (the multiple-expansion trap above)

**Negative controls (the guard was made to fail, both directions).**
- RED on the committed pre16 tree, final test bytes: exit 1 —
  `FAIL: Gate D: 1 file(s) ship in the tarball's etc/nftables.d/ but are NOT staged by the install recipe (the pre16 defect)` / `NOT SHIPPED: etc/nftables.d/31-admin-board-not-guest-reachable.nft`, and the same line again via Gate E.
- Gate C control: injecting the dead `welcome.html` install line (the module #517 break) into the same tree makes Gate C fail and names it — `Makefile:463  packaging/files/tollgate-captive-portal-site/welcome.html`.
- Gate H control: the FIRST published form of this fix (commit `04e54509`, the shell loop) makes Gate H fail and names the line — `521: \t\t$(INSTALL_DATA) "$$nft" $(1)/etc/nftables.d/ || exit 1; \`.
- GREEN after the wildcard rewrite: `Gate D: etc/nftables.d/ parity exact both ways (3 file(s), 0 exclusions)`, `Gate E: every tarball packaging/files/ file outside 'tollgate-captive-portal-site/' is staged`, `Gate H: no $$shell-variable use in the install recipe`, `test-pkg-tarball-parity: PASS` (exit 0).
- The rewritten line staged all three fragments byte-identically under a plain-`make` run of the real recipe body (`31-*.nft` = `7655fe2b…`, mode 644, exactly what the old `INSTALL_DATA` lines produced for the other two).

**Other feed gates re-run against pre17:** `test-devendored.sh` exit 0 (Gates A–E),
`test-feed-ci.sh` exit 0 (`PKG_VERSION=0.6.0_alpha4_pre17`),
`sh -n` on the modified scripts. `test-version.sh` was bumped to track
`PKG_VERSION=0.6.0_alpha4_pre17` (the assertion still matches `0.6.0`, because the
binary reports the SOURCE version `v0.6.0-alpha4-g2796d96`).

**Not run here:** the gh-action-sdk multi-arch build — CI runs it
(`multi-arch-test-build.yml` for `aarch64_cortex-a53` and `x86_64`), and the
published-release check below is the same `apk manifest`/`apk extract` pair used on
the pre16 artifact above.
