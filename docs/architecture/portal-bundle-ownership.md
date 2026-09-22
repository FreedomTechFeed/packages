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
pre7/pre8/pre10/pre11/pre12/pre13 bundle churn. Upstream the module repo
gitignores `packaging/files/tollgate-captive-portal-site/assets/` (commit
"build portal assets from source, stop committing minified JS") — the repo
itself declares these are build output and must never be tracked.

## The single source of truth

`net/tollgate-wrt/vendor.lock.json` pins **one** immutable portal commit
(now the full 40-char SHA `4f74a6dd5a7c4dc985d55e72978a076cf8bbebaf`). It is the
authoritative pin for exactly what the package ships: the guest portal SPA, the
admin board, and the rpcd ACL.

`npm run build` at that pin (the portal repo's `scripts/build-all.mjs`) emits
`build/` (React guest portal + balance page) and `build/admin/` (Preact admin
board). Verified byte-identical to the previously-committed feed copies
(2026-09-22, local harness):
- `diff -r <rebuild>/build net/tollgate-wrt/files/tollgate-captive-portal-site`
  (excl. `admin/`, `welcome.html`, `logo{192,512}.png`) → identical except the
  module-owned `welcome.html`, which the portal build never emits.
- `diff -r <rebuild>/build/admin net/tollgate-wrt/files/tollgate-admin` →
  byte-identical.

## Placement map

### Built SPAs — OWNER: `OpenTollGate/tollgate-captive-portal-site` → built in FEED CI

| feed dir | contents | WHY it must not be committed here |
|---|---|---|
| `files/tollgate-captive-portal-site/` | guest portal SPA (`splash.html` + hashed `assets/*.js\|css`, `asset-manifest.json`, `404.html`, `balance.html`, `favicon.ico`, `logo*.png`, `manifest.json`, `locales/en.json`) | **build output** — vite production build of the portal repo. `index-CLv4MW7b.js` (426,868 B) is minified JS with a content hash. The portal repo gitignores them; they exist only after `npm run build`. |
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

### `welcome.html` — OWNER: `OpenTollGate/tollgate-module-basic-go` (module)

`welcome.html` is **not** produced by the portal build — the portal repo never
emits it. It is module-owned, tracked under
`packaging/files/tollgate-captive-portal-site/welcome.html`, and is byte
identical in the module (at feed pin `170b4bd`) and the previously-committed
feed copy. It now ships **from the module source tarball**:
`$(INSTALL_DATA) $(PKG_TARBALL_DIR)/packaging/files/tollgate-captive-portal-site/welcome.html ...`.
Any future change originates upstream in the module. (Feed-A/freedomtech-feed
carried a duplicate; the active feed, FreedomTechFeed/packages, now installs it
from the tarball only.)

### Vendored SOURCE files — OWNER: `OpenTollGate/tollgate-captive-portal-site`, still vendored as source

These are **not** build output — they are tracked source in the portal repo, so
vendoring them (with a drift guard) is the correct pattern, not a #335
violation. They remain committed under `files/` and the guard byte-compares them
against the **pinned release commit** (`vendor.lock.json` → `portal_commit`), not
portal `main` — see "What the drift guard now does" below.

| feed file | portal source | status |
|---|---|---|
| `files/uci-defaults/92-tollgate-admin-setup` | `packaging/files/etc/uci-defaults/92-tollgate-admin-setup` | **VENDORED SOURCE.** In sync with the pre14 pin `992cf7f1` (`ebe1332f…`, 8937 B). Ordering enforced: portal merges first, then the feed re-pins (pin bump + re-vendor from the SAME commit, atomic). |
| `files/rpcd/tollgate` (exec sh) | `openwrt/rpcd/tollgate` | IN SYNC with the pin (`05852546…`). VENDORED SOURCE. |
| `files/rpcd/tollgate_acl.json` | `openwrt/rpcd/tollgate_acl.json` | IN SYNC with the pin (`14ffed79…`). VENDORED SOURCE, and locked in `vendor.lock.json`. |

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
   drifts from a full immutable SHA; Gate D fails if `welcome.html` stops coming
   from the module tarball.

## Test evidence (run 2026-09-22)

- RED: `sh net/tollgate-wrt/test-devendored.sh` → exit 1 (Gates A–D fail on master).
- GREEN: after the fix → exit 0.
- Byte-identity of staged bundle vs committed pre-fix bundle: `diff -r` clean
  (except module-owned `welcome.html`).
- `build-portal-bundle.sh` end-to-end: `portal=… @ 4f74a6dd5a…` staged 18 guest
  + 12 admin files, verified against `vendor.lock.json`, exit 0.
