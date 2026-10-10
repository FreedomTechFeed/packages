# RC blocker: admin board not served + password UX — plan

Status: active (2026-10-10). Owner: c03rad0r. Workstream ticket for the
`pre29` fix. Fork-local.

Router under test: **pre28** (`tollgate-wrt-0.6.0_rc1_pre28`), installed via
`apk` on vanilla OpenWrt 25.12.5, at `192.168.1.1` behind CobradorWave.

---

## 1. Confirmed defect (live)

Read-only over CobradorWave, interface-bound to `enx00e04c633a90` → `192.168.1.1`:

| probe | result |
|---|---|
| `http://192.168.1.1/` | 200 |
| `http://192.168.1.1:8080/` | **307 → https://192.168.1.1/** |
| `http://192.168.1.1:2121/` | 200 (`kind:10021` advertisement) |
| `https://192.168.1.1/` | 200 but **it is LuCI** (`<meta refresh URL=cgi-bin/luci/>`, "LuCI - Lua Configuration Interface") |
| `https://192.168.1.1:8443/`, `:8090/` | **nothing (000/timeout)** |

**The board is served on neither pair, and LuCI owns the entry pair.**
Intended default is the opposite (`entry_ui=board`: board on `:8080/:443`,
LuCI on `:8090/:8443`).

Two compounding causes:
1. **Credential-before-gate.** The fail-closed gate deletes the board's
   `uhttpd.admin` listeners while root's `/etc/shadow` hash is empty; and it
   only (re)serves on install/upgrade. If root was empty when the gate ran at
   install, the board ends up off and a later `passwd root` does not bring it
   back. (`:8090/:8443` = nothing ⇒ `uhttpd.admin` has no listeners ⇒ the gate
   refused, or never re-ran after the credential existed.)
2. **Mapping never flipped to `board`.** The module `99` resolves `board` vs
   `luci` from `/etc/tollgate/entry-ui-mapping`, which the feed's
   `92/999` writes only on a completed run. On a fresh install `99` runs
   **before** `92/999`, sees no marker, and writes **LuCI on the entry pair**;
   `92/999` then cannot move LuCI to the secondary pair (D3), so the mapping
   stays `luci` and `:443` serves LuCI.

## 2. Fixes (author → merge → build → verify)

### 2a. Board determinism (module + portal)
Replace the *runtime* marker with a **static capability sentinel shipped in the
feed package** (present before any uci-defaults run). Both writers resolve the
mapping from it, independent of order:
- module `99-tollgate-setup` → writes LuCI on the **secondary** pair;
- portal `92-tollgate-admin-setup` → binds the board on the **entry** pair.
Torn-pair protection is retained (old feed without the sentinel ⇒ repair to `luci`).

### 2b. Credential-before-gate / board is actually served
Ensure a usable credential exists **before** the gate's decision at install, and
that a first-run path exists when it does not (2c-A). Verify the gate then
leaves `uhttpd.admin` listening on the entry pair.

### 2c. Password UX — A + B, no CLI dumps
- **A (web first-run):** portal board serves a **pre-auth first-run page** while
  the credential is unset/provisional, forcing **root password + private WiFi
  passphrase**; a **narrow, one-shot, management-path-only** pre-auth rpcd
  method; disabled once set.
- **B (install prompt):** installer prompts for root + WiFi and passes
  `TOLLGATE_ADMIN_PASSWORD` + new `TOLLGATE_PRIVATE_WIFI_PASSWORD`; module `99`
  applies both, no provisional state.
- **Remove the printed dumps** in `99`:
  - admin: `printf 'TollGate: root had no password; generated one … shown once: %s'` (`:1411`)
  - wifi: `log "Private key: $private_key"` / "Generated new private WiFi key" (`:2301`, `:2306`)

### 2d. Feed
Repin/re-vendor module+portal (the atomicity boundary) and cut `pre29`.

## 3. Repos
- **OpenTollGate/tollgate-module-basic-go** — `99-tollgate-setup` (mapping via
  sentinel, credential ordering, remove dumps, `TOLLGATE_PRIVATE_WIFI_PASSWORD`).
- **OpenTollGate/tollgate-captive-portal-site** — first-run page + WiFi field,
  pre-auth rpcd method, `92-tollgate-admin-setup` sentinel.
- **OpenTollGate/tollgate-installer** — prompt for root + WiFi (B).
- **FreedomTechFeed/packages** — repin/re-vendor + `pre29`.

## 4. Router connectivity (verification)
`enx00e04c633a90` shares an L2 with the office DHCP (`10.60.250.1`, an OpenWrt
box), so it holds a `10.60.250.x` lease and the router's input firewall refuses
SSH from that source. **No static address** — obtain the router's own
`192.168.1.x` DHCP lease on a dedicated/isolated link (or a dedicated DHCP
client/macvlan that accepts the router's offer), then `ssh root@192.168.1.1`.

## 5. Verification (my job)
1. Merge the fix PRs.
2. Get `ssh root@192.168.1.1`.
3. Cut `pre29`; release build publishes.
4. Flash vanilla 25.12.5; install `pre29` via `apk`; assert:
   - install output has **no generated password/WiFi key**;
   - `https://tollgate.lan/` serves the **board**; board on `:8080/:443`,
     LuCI on `:8090/:8443`;
   - first-run forces **root + WiFi**; after setting, the board loads;
   - repeat via the offline-bundle path.
5. Paste raw evidence, then hand to the operator for their manual test.

## 6. Deferred
- Fast-builds builder image (builds are fast enough for now).
