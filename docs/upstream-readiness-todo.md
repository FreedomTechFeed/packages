# Upstream readiness — TODO for submitting `tollgate-wrt` to `openwrt/packages`

**Status:** Proposed (2026-10-10). Documentation only — **execute after the
current release** (`v0.6.0-rc1`), per operator instruction.

**Related:** `docs/upstream-submission.md` and PR #62 ("Gate L",
`net/tollgate-wrt/UPSTREAM-MANIFEST.txt` + `test-upstream-fidelity.sh`). Gate L
makes the fork-local / upstream byte-split mechanical. This file is the action
list that gets the *extracted submission* to build and pass review.

**Headline:** the "fast registry" machinery and the "upstream-mergeable"
package already occupy different bytes — an upstream PR is per-path and
`.github/**` never travels. What remains is to prove the extracted subset builds
and to tidy the reviewed artifact.

---

## Checklist

### 0. Prerequisites
- [ ] Merge PR **#62** (Gate L: `UPSTREAM-MANIFEST.txt` + `test-upstream-fidelity.sh`
      + `docs/upstream-submission.md`). Note: `docs/upstream-submission.md` and
      `docs/upstream-readiness-todo.md` (this file) are fork-local docs; they do
      **not** travel upstream.
- [ ] Delete the stale `tollgate-wrt-upstream` branch (`9bd69d9`) — it is not
      part of the one-tree design.

### 1. The real blocker — portal/admin bundle source
`net/tollgate-wrt/Makefile` installs from generated paths:
```
$(CP) $(PKG_MAKEFILE_DIR)files/tollgate-captive-portal-site/. …
$(CP) $(PKG_MAKEFILE_DIR)files/tollgate-admin/. …
```
These dirs are **not committed** — they are produced at CI time by the
fork-local `scripts/build-portal-bundle.sh` (build-in-CI rule #335). In an
extracted upstream tree the script is absent and the dirs do not exist, so
`make package/tollgate-wrt/compile` fails. Gate L's **L5 will not catch this**
(the dirs sit under `files/*`, auto-classified `upstream`).

Pick one and record the decision:
- [ ] **Option A (recommended):** change the install recipe to take the portal
      from the pinned module source tarball, e.g.
      `$(CP) $(PKG_TARBALL_DIR)/packaging/files/tollgate-captive-portal-site/. …`
      and the admin board from the same tarball. The module tarball at the pin
      already ships `packaging/files/tollgate-captive-portal-site/`. This makes
      the package self-contained from `PKG_SOURCE`.
- [ ] **Option B:** commit the built bundle into the submission's `files/`
      (prebuilt assets in `files/` are accepted by some upstream packages, but
      expect reviewer scrutiny, and it conflicts with the fork's #335 rule).

### 2. Tidy the reviewed artifact
- [ ] Strip the ~27 fork-local comment references from the Makefile
      (`test-pkg-tarball-parity.sh` ×13, `scripts/build-portal-bundle.sh` ×5,
      `vendor.lock.json` ×5, `test-devendored.sh` ×3,
      `.github/scripts/check-vendor-drift.sh` ×1). None is a functional
      reference (L5 confirms), but a reviewer should not receive commentary on a
      harness that is not in the submission.

### 3. Prove a clean build
- [ ] In a fresh `openwrt/packages` checkout, extract the `upstream`-classified
      subset (`git ls-files net/tollgate-wrt` filtered by `UPSTREAM-MANIFEST.txt`).
- [ ] `./scripts/feeds update -a && ./scripts/feeds install -a`
- [ ] `make package/tollgate-wrt/compile` — must produce `.apk`/`.ipk`.
- [ ] Confirm no upstream-classified file functionally references a fork-local
      path (L5 green) **and** that the package builds from `PKG_SOURCE` alone.

### 4. Conventions & metadata
- [ ] `PKG_MAINTAINER`, `PKG_LICENSE=GPL-3.0-only`, `PKG_LICENSE_FILES` present
      (already true).
- [ ] Immutable `PKG_SOURCE_VERSION` (40-char SHA) + `PKG_HASH` (already true).
- [ ] `include ../../lang/golang/golang-package.mk` (already correct upstream).
- [ ] Commit **Signed-off-by** on every commit; real name + real email.
- [ ] Commit-subject prefix consistency — decide `tollgate-wrt:` vs
      `tollgate-module-basic-go:` and use one consistently.

### 5. Dependencies present upstream
- [ ] `net/nodogsplash` exists in `openwrt/packages` (verified).
- [ ] `lang/golang` helpers exist (verified).
- [ ] `ca-bundle` provided on both lanes (verified: 24.10 opkg + 25.12 apk).

### 6. Submission mechanics
- [ ] Create a per-path feature branch in a clean `openwrt/packages` fork.
- [ ] Open the upstream PR touching **only** `net/tollgate-wrt/**` (the
      `upstream` set).
- [ ] Keep this fork's `master` CI (`.github/**`, harness, pins) untouched —
      those bytes never travel.

---

## Known non-conformance (accepted for now)

The Makefile names five fork-local artifacts across ~27 comment lines. L5
confirms zero functional references, so the extracted tree still builds; the
comments are a tidiness issue, handled in §2.
