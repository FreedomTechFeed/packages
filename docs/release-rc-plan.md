# Release RC plan — TollGate (coordination doc)

Fork-local coordination doc (never travels upstream; see Gate L). Owner: c03rad0r. Created 2026-10-10.
Repos in scope: `FreedomTechFeed/packages` (feed, `master`), `OpenTollGate/tollgate-module-basic-go` (module, `main`), `OpenTollGate/tollgate-captive-portal-site` (portal, `main`).

---


Status: active coordination doc. Checklist lives in [`CHECKLIST.md`](./CHECKLIST.md).
Owner: c03rad0r. Created 2026-10-10.

Repos in scope:

- `FreedomTechFeed/packages` (the feed; default `master`) — build, release assets, upstream submission.
- `OpenTollGate/tollgate-module-basic-go` (the module; default `main`) — router backend.
- `OpenTollGate/tollgate-captive-portal-site` (the portal; default `main`) — guest + admin SPAs.

---

## A. Root cause of the pre26 apk-path failure (evidence)

The admin board ("configUI") is **fail-closed**: the portal's admin setup script
(`92-tollgate-admin-setup`, staged from the pinned portal tree) deletes
`uhttpd.admin`'s listeners while root's `/etc/shadow` hash is empty, because
rpcd's `session.login` accepts *any* password in that state. The credential is
created by `99-tollgate-setup`.

pre26 shipped the gate **installed as `92`**, so the boot-time glob
`90, 92, 99` ran the gate *before* the credential:

- feed pre26 (`net/tollgate-wrt/Makefile` @ `7b7944cd6`): postinst loop ran
  `90, 99, 92`, but the file was installed as `92` → **first boot** runs
  `90, 92, 99` → gate kills the board with nothing to restore it.
- the installer path works because it sets the root password first, then runs
  its own deploy order (`… password → install → brand → portal → services → health`).
- module `#838` ("run the fail-closed admin gate LAST", `b6f7aa74`, merged
  **2026-10-10**, after pre26) stages it as `999` on both recipes; feed
  `master` also installs `999` and postinst runs `90, 99, 999`.
- module `#82` (operator chooses the admin password at install time) also
  merged **after** pre26.

**Conclusion:** pre27 built from current module `main` + feed `master` should
fix the apk-path board. That is the release gate.

---

## B. Workstream 1 — Fast builds in `FreedomTechFeed/packages`

All changes are `.github/**` / fork-local; per `#62`'s Gate L they never travel
to `openwrt/packages`.

| # | Change | How | Acceptance |
|---|---|---|---|
| 1.1 | Prebaked builder image | New workflow builds `FROM openwrt/sdk:<ver>@<digest>` + `feeds update`/`make defconfig`/dependency closure, pushes `ghcr.io/FreedomTechFeed/tollgate-sdk-<arch>:<ver>`. PR + release lanes `FROM` it and compile only `tollgate-wrt`. | Cold lane time drops from ~35–42 min toward compile+link; image rebuild only on SDK/pin change. |
| 1.2 | Registry cache | Add `cache-from/cache-to: type=registry,ref=ghcr.io/freedomtechfeed/sdk-cache:<arch>` to the SDK build. | Second run warm and stable across jobs. |
| 1.3 | (Fallback) split Go compile out of the SDK | Native `go build` job, SDK packages only — mirrors the module's workflow. | Removes the ~1200 s dependency-closure rebuild. |
| 1.4 | GHCR auth | Grant the fork's workflows `packages: write`. | Push/pull to GHCR succeeds. |

Deliver on a branch, exercised by a real PR run; keep Gate L green.

---

## C. Workstream 2 — Verify the happy path on both install paths, then cut the RC

### C1. Prepare pre27
1. Feed pin bump: `PKG_SOURCE_VERSION`/`PKG_HASH` → module `main` tip
   (≥ `b6f7aa74`, excluding the post-release `#706`), re-vendor
   `vendor.lock.json` `portal_commit` → the merged portal revision (`#68`),
   bump `PKG_VERSION` → `0.6.0_rc1_pre27`, `PKG_RELEASE:=1`.
2. Tag `v0.6.0-rc1-pre27` → `release-publish.yml` produces per-arch
   `.apk`/`.ipk`/offline bundles + signed `SHA256SUMS`.
3. No RC tag (`v0.6.0-rc1`) until C3 passes.

### C2. Static verification (no hardware)
Unpack every pre27 asset and assert:
- `/etc/uci-defaults/999-tollgate-admin-setup` present (and **no** `92-…`).
- `/www/tollgate/index.html` + assets present (admin board webroot).
- `/etc/tollgate/tollgate-captive-portal-site/splash.html` + assets present.
- `entry-ui-mapping` marker logic + `__ADMIN_HOME__` substituted; rpcd plugin + ACL present.
- `postinst` runs `90, 99, 999` in that order.
- `test-pkg-tarball-parity` / `test-devendored` green on the pin.

### C3. Hardware verification (user-driven; exact commands in the run book)
`tollgate-installer/docs/pre26-install-runbook.md`:
- Path A (wizard) pinned `--tag v0.6.0-rc1-pre27`.
- Path B1 offline bundle (WAN-less) on MT3000 + AR300M.
- Path B2 direct `.apk` (25.12.x) — the path that failed in pre26 → board must load.
- Path B3 direct `.ipk` (24.10.x) — least proven.
- Shared acceptance (§4) + board at entry port, LuCI on secondary pair,
  `tollgate.lan` → board, captive detection, Cashu payment, Lightning lane.

**Gate:** both Path A and Path B load the board → **then** cut `v0.6.0-rc1`.

### C4. Payment verification
Confirm the shipped portal bundle drives the real Lightning lane (local
`src/helpers/lightning.js` was a placeholder) and the Cashu / kind-21000 lane,
against module `main`'s `/ln-invoice`, `/balance`, `/usage`, `/session-state`.

---

## D. Workstream 3 — Upstream readiness TODO doc (documentation now, exec after release)

- **Where:** `FreedomTechFeed/packages/docs/upstream-readiness-todo.md`, merged to `master`.
- **Contents:**
  1. **Portal/admin bundle source** — the one real blocker: the Makefile installs
     from generated `files/tollgate-*`, which is CI-built by fork-local
     `build-portal-bundle.sh`; decide *install from
     `$(PKG_TARBALL_DIR)/packaging/files/…`* vs *commit the bundle in the submission*.
  2. Strip the ~27 fork-local comment references from the Makefile for review tidiness.
  3. Prove a clean build in a fresh `openwrt/packages` checkout
     (`feeds update/install` + `make package/tollgate-wrt/compile`).
  4. Signed-off-by + per-path submission branch; commit-subject prefix consistency
     (`tollgate-wrt` vs `tollgate-module-basic-go`).
  5. Confirm deps exist upstream (`net/nodogsplash`, `lang/golang`, `ca-bundle`).
  6. Merge `#62` (Gate L) first; delete stale `tollgate-wrt-upstream` branch.

---

## E. Workstream 4 — PWA + client-side Cashu wallet plan doc (documentation now, exec after release)

- **Where:** `OpenTollGate/tollgate-captive-portal-site/docs/pwa-client-wallet-plan.md`,
  merged to `main`; cross-link module `docs/architecture/session-ticket-decision.md`.
- **Contents:**
  - Current-state gaps: no service worker, no IndexedDB; `@cashu/cashu-ts` `2.9.0`
    present but only used to decode tokens (no `CashuWallet`); one-shot kind-21000
    token per purchase.
  - Proposed: **Near-term** PWA shell (SW + offline UI, manifest hardening) on the
    existing flow — low risk, portal-only. **Medium** `cashu-ts` `CashuWallet` +
    IndexedDB as a UX layer. **Real rail**: Spillman channels (`cdk-spilman`/MONAD)
    per the ADR, gated on CDK wallet + channel-capable client wallet.
  - Reconcile with ADR R1–R6 (address session-scoped, no join, no auto-rotation,
    MAC-blind journal; no router-side owed-value/refund records) — i.e. do **not**
    build a bespoke stored-value drip wallet.

---

## F. Sequencing

1. WS1 (fast builds) on a branch + WS2-C1 (pre27 pin bump).
2. Tag pre27; static checks (C2); user runs C3/C4 on hardware.
3. Both install paths pass → cut `v0.6.0-rc1`.
4. After release: land WS3 doc (feed `master`) and WS4 doc (portal `main`);
   merge module `#706` + installer pairing on a later cycle.
5. CI runner (NetBird hop) only if a required self-hosted/ngit lane blocks a PR —
   the release lanes are `ubuntu-latest`, so it is off the critical path.

---

## Appendix — checklist snapshot (living copy kept with the owner)


Living tracker. Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked.
Last updated: 2026-10-10.

## WS1 — Fast builds in FreedomTechFeed/packages   → PR #65 (OPEN)
- [x] 1.4 GHCR `packages: write` used by the new workflow
- [x] 1.1 Prebaked builder image workflow (`.github/workflows/build-tollgate-sdk-image.yml`)
- [x] 1.1 `.github/sdk-builder/Dockerfile` (FROM exact SDK + warm closure)
- [x] 1.1 PR + release lanes wired to consume it via `CONTAINER` (opt-in)
- [x] 1.2 Registry cache (`type=registry` cache-from/cache-to) added
- [x] docs: `docs/fast-builds.md`
- [ ] PR #65 reviewed & merged (opt-in; default OFF, safe)
- [ ] Validation run: build the image, make it public, set `TOLLGATE_SDK_IMAGE`, compare lane time
- [ ] 1.3 Fallback (split Go compile out of SDK) — only if 1.1/1.2 insufficient

## WS2 — Release happy path (pre27 → RC)
- [x] Confirmed root cause: feed #57 moved the fail-closed admin gate to `999` (gate-last)
- [x] C1a/C1b Feed pin bump: module `b6f7aa74`, `PKG_HASH=6bf16f63…` (method replayed) → PR #66 MERGED
- [ ] C1c `vendor.lock.json` portal re-vendor to portal #68 (forced password) — separate repin
- [x] C1d `PKG_VERSION` → `0.6.0_rc1_pre27`
- [x] C1e Tag `v0.6.0-rc1-pre27` created → release assets build **in progress**
- [ ] C2 Static asset checks on the pre27 assets (999 gate staged; no 92; board+portal webroots; marker; postinst 90,99,999)
- [ ] C3 Path A wizard deploy on `v0.6.0-rc1-pre27` (user)
- [ ] C3 Path B1 offline bundle MT3000 + AR300M (user)
- [ ] C3 Path B2 direct .apk 25.12.x — board loads (user) **[the pre26 failure]**
- [ ] C3 Path B3 direct .ipk 24.10.x (user)
- [ ] C3 Shared acceptance §4 + tollgate.lan → board; LuCI secondary pair (user)
- [ ] C4 Cashu (kind-21000) payment lane verified (user)
- [ ] C4 Lightning lane verified against module main `/ln-invoice` (user)
- [ ] CUT `v0.6.0-rc1` — only after C3 both paths pass

## WS3 — Upstream readiness TODO doc   → DONE
- [x] Doc written: `FreedomTechFeed/packages/docs/upstream-readiness-todo.md`
- [x] Merged to `master` (PR #64)
- [ ] (exec, after release) portal/admin bundle source decision
- [ ] (exec, after release) clean-build proof in fresh openwrt/packages

## WS4 — PWA + client-side Cashu wallet plan doc   → DONE
- [x] Doc written: `OpenTollGate/tollgate-captive-portal-site/docs/pwa-client-wallet-plan.md`
- [x] Merged to `main` (PR #69)
- [ ] (exec, after release) near-term PWA shell scoped
- [ ] (exec, after release) Spillman-channel rail tracked per ADR

## WS5 — Deferred / later cycle
- [ ] Merge module #706 + installer `!`-SSID pairing (next cycle, post-RC)
- [ ] CI runner (NetBird hop) only if a required self-hosted lane blocks a PR

## Notes / decisions
- RC is NOT cut until the user has tested pre27 via **both** install paths and is happy.
- Docs (WS3/WS4) landed now; implementation deferred until after the release.
- All WS1 changes are fork-local `.github/**` and never travel upstream (Gate L).
- pre27 is a **pre-release** (not the RC); user tests it, then `v0.6.0-rc1` is cut.
