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
pre7/pre8/pre10/pre11/pre12/pre13/pre15 bundle churn. Upstream the module repo
gitignores `packaging/files/tollgate-captive-portal-site/assets/` (commit
"build portal assets from source, stop committing minified JS") — the repo
itself declares these are build output and must never be tracked.

## The single source of truth

`net/tollgate-wrt/vendor.lock.json` pins **one** immutable portal commit (now
the full 40-char SHA `51a1429bb3b5e3b41eb1001bfa612543ba1fcd1a`, the revision the
pinned module commit `42496214` declares in its
`packaging/build-inputs.json` → `.portal.commit`). It is the authoritative pin
for exactly what the package ships: the guest portal SPA, the admin board, and
the rpcd ACL. One release, not two — the module pin and the vendored portal pin
always move together in one commit.

`npm run build` at that pin (the portal repo's `scripts/build-all.mjs`) emits
`build/` (React guest portal + balance page) and `build/admin/` (Preact admin
board). For the pre15 pin the evidence is the builder's own byte-verification:
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
| `files/tollgate-captive-portal-site/` | guest portal SPA (`splash.html` + hashed `assets/*.js\|css`, `asset-manifest.json`, `404.html`, `balance.html`, `favicon.ico`, `logo*.png`, `manifest.json`, `locales/en.json`) | **build output** — vite production build of the portal repo. `index-BDGoMmEt.js` (360,000 B) is minified JS with a content hash. The portal repo gitignores them; they exist only after `npm run build`. |
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

### `welcome.html` — REMOVED at the pre15 pin

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
`170b4bd`). The file must not be re-vendored into the feed either — that would be
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
| `files/uci-defaults/92-tollgate-admin-setup` | `packaging/files/etc/uci-defaults/92-tollgate-admin-setup` | **VENDORED SOURCE.** In sync with the pre15 pin `51a1429` (`ebe1332f…`, 8937 B) — and byte-identical at the OUTGOING pin `992cf7f1` too, so pre15 re-pinned this file without changing it. Ordering enforced: portal merges first, then the feed re-pins (pin bump + re-vendor from the SAME commit, atomic). |
| `files/rpcd/tollgate` (exec sh) | `openwrt/rpcd/tollgate` | IN SYNC with the pre15 pin (`05852546…`); identical at both pins. VENDORED SOURCE. |
| `files/rpcd/tollgate_acl.json` | `openwrt/rpcd/tollgate_acl.json` | IN SYNC with the pre15 pin (`14ffed79…`); identical at both pins. VENDORED SOURCE, and locked in `vendor.lock.json`. The builder SKIPS this entry (it is tracked source, not a build output), so it was proven separately against `raw.githubusercontent.com/.../51a1429/openwrt/rpcd/tollgate_acl.json`. |

### Runtime files — OWNER: `OpenTollGate/tollgate-module-basic-go` (module, via tarball)

Already correct in the active feed (FreedomTechFeed/packages): init.d, uci-99,
nftables.d, hotplug.d, usr/bin helpers, keep.d are installed from
`$(PKG_TARBALL_DIR)/packaging/files/…` — never vendored. No change needed.

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
   `welcome.html` the pre15 pin deleted comes back — as a `$(PKG_TARBALL_DIR)`
   install line (a build break at this pin) or as a re-vendored copy under
   `files/`.

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
