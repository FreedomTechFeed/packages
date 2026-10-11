# Plan: no generated credentials — the user always provides them

Status: active (2026-10-11). Owner: c03rad0r. Targets the next pre-release (`pre30`).

## 1. The failure this fixes (evidence)

The installer and the package both manage the root credential, and they **collide**:

1. Installer **step 4** (`internal/app/deploy.go:324 ensureRootCredential`): on a fresh
   router (empty root) it **generates** a password, persists it to a file, and
   **DEFERS** setting it until after the health check (`:366-368`, returns
   `effectivePassword == ""`).
2. So during **step 6 (install package)** the router's root is still **empty**.
3. The module's `99-tollgate-setup` runs, sees an empty root, and **generates and
   sets its own** credential (`enforce_admin_credential`, `state=empty`).
4. The installer's transport re-acquire (`transport_reacquire.go:62,94`) re-dials with
   `req.Password` = `""` → **auth fails** → "Lost the SSH transport … before the health
   check" (`deploy.go:1943`) → **"router stopped answering" at step 6** →
   `finalizeRootCredential` (`:1990`) never runs → **lockout**.
5. `#850` (now merged) stopped the module **printing** that generated password, so the
   last recovery path is gone. (pre29 + the old installer is the unsafe combination.)

Manual `apk`/`opkg` "Operation not permitted" after the failed deploy is a downstream
symptom (no working uplink).

## 2. Decision (operator)

- **No generate-and-show anywhere.** The admin and private-WiFi passwords are
  **provided by the user**.
- **Installer path:** the wizard **requires** the admin + private-WiFi password.
- **Manual `apk` path: M1** — the install **requires** `TOLLGATE_ADMIN_PASSWORD`
  (+ `TOLLGATE_PRIVATE_WIFI_PASSWORD`); without it the module establishes **no**
  credential (it never generates).

## 3. Changes

### 3a. Installer (`OpenTollGate/tollgate-installer`) — extend merged #104
- Make `adminPassword` + `privateWifiPassword` **required** in the wizard (distinct
  from the SSH "Router password"); block Deploy if missing/weak (`< 8` chars).
- Pass the **effective** password on the install command:
  `TOLLGATE_ADMIN_PASSWORD=<supplied> TOLLGATE_PRIVATE_WIFI_PASSWORD=<supplied> apk add …`.
- A *supplied* password takes `deploy.go:327`'s branch → root is set at **step 4**,
  not deferred → the module never sees an empty root → no re-key → the re-acquire
  survives the module's network restart.
- Update installer tests that currently deploy with no supplied password.

### 3b. Module (`OpenTollGate/tollgate-module-basic-go`) — on top of merged #850
- `TOLLGATE_ADMIN_PASSWORD` set → use it; never generate, never print (done).
- Unset → **M1**: do **not** generate from an empty root; refuse to establish a
  credential and print guidance (`TOLLGATE_ADMIN_PASSWORD='…' apk add …`).
- `TOLLGATE_PRIVATE_WIFI_PASSWORD` set → use it (done); unset → keep the existing
  key if present, else leave it (no dump).

### 3c. Portal (`OpenTollGate/tollgate-captive-portal-site`)
- No change for M1 (first-run page from #70 remains for the provisional case).

### 3d. Feed (`FreedomTechFeed/packages`)
- Re-vendor/re-pin module + portal after 3a–3c; `PKG_VERSION` → `0.6.0_rc1_pre30`.

### 3e. Docs
- `docs/install-runbook.md` (installer): the manual path now **requires**
  `TOLLGATE_ADMIN_PASSWORD` + `TOLLGATE_PRIVATE_WIFI_PASSWORD`.
- This plan + the checklist.

## 4. Pin targets at time of writing
- module main: `362e5d5f851970a1b174aa87bc2e7b6d8c25c5e3` (#850 merged)
- portal main: `c11e6053e5572cd3c4835d2cf70266f61e567a4b` (#70 merged)
- installer main: `737336b78b1413e9fae577b5999ba26814b1db5f` (#104 merged)
- feed master: `18a0afb5b89e3aea7dc527053bc9d0281a2e325e` (pre29)
- pre29 is **unsafe via the installer** — do not cut the RC on it.

## 5. Sequence
1. Installer PR: required fields + required-value pass.
2. Module PR: M1 (never generate when unset).
3. Feed PR: re-pin + re-vendor → tag `v0.6.0-rc1-pre30`; release build publishes.
4. Static verification, then the **reset router**: installer path (provide admin+wifi →
   no stall; SSH works with the provided password; `tollgate.lan` → board on
   `:8080/:443`; LuCI on `:8090/:8443`; no credential in any log) + manual path
   (`TOLLGATE_ADMIN_PASSWORD=… apk add …` → served; without → refused with guidance).
5. Hand to the operator.

## 6. Risks
- Installer test suite assumes generated credentials in places — required password
  will surface them.
- The module must not regress the "already set" and "locked" states (leave them alone).
