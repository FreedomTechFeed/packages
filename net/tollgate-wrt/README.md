# tollgate-wrt — the canonical OpenWrt feed recipe

This recipe builds [`OpenTollGate/tollgate-module-basic-go`](https://github.com/OpenTollGate/tollgate-module-basic-go)
from its pinned source tarball via `golang-package.mk`. It is the
**canonical** packaging brain of a three-repo ecosystem that deliberately
points at each other — single source of truth, single source of authority,
single source of bugs and fixes:

| Repo | Owns | File bugs there for |
| --- | --- | --- |
| [`OpenTollGate/tollgate-module-basic-go`](https://github.com/OpenTollGate/tollgate-module-basic-go) | the Go source, the release tarball, the **build contract** (`packaging/build-contract.json`, generated and fenced there: binary set, module map, go minimum, pinned toolchain) | anything in `src/`, packaging payloads under `packaging/files/`, contract contents |
| **this repo**, `net/tollgate-wrt` | **this recipe**: tarball pin (`PKG_SOURCE_VERSION`/`PKG_HASH`), the apk-legal version scheme, portal vendoring under `vendor.lock.json` (build-in-CI), the parity + contract fences, per-arch publish | the recipe, pin bumps, portal vendoring, feed CI |
| [`FreedomTechFeed/feed`](https://github.com/FreedomTechFeed/feed) | a **wrapper mirror** of this directory for standalone `src-git` consumers — synced by its `scripts/sync-from-canonical.sh`, never hand-edited | nothing — fixed here, then re-synced |

## The contract is the interface

The release tarball carries `packaging/build-contract.json` (upstream
#1021; codeload tarballs are repo snapshots, so every tag and every SHA
pin ships it). [`test-build-contract.sh`](test-build-contract.sh) enforces
this recipe against it: binary parity both directions, the contract's go
minimum vs **this feed's own** `lang/golang`, and module sanity in the
pin. When upstream changes a contract-governed fact, this fence goes red
on the next repin **until the recipe catches up — that is the intended
signal, not breakage**: do not "fix" it by weakening the recipe; repin or
extend here, or fix upstream if the contract itself is wrong.

The other fences here, same doctrine:
[`test-pkg-tarball-parity.sh`](test-pkg-tarball-parity.sh) (recipe ↔
tarball runtime files, both directions — born from the pre16
missing-nft-fragment defect), [`vendor-drift.yml`](../../.github/workflows/vendor-drift.yml)
(portal pinned-bytes under `vendor.lock.json`),
[`test-uci-defaults-order.sh`](test-uci-defaults-order.sh),
[`test-devendored.sh`](test-devendored.sh).

## Repinning procedure

Bump `PKG_SOURCE_VERSION` + `PKG_HASH` (and the `PKG_VERSION` pre-tag
counter per the Makefile's version block), review the parity + contract
gates this directory ships, and let CI's SDK matrix prove the build. The
full incident history and reasoning lives in the Makefile's own comments —
read them before changing the build or install recipes.
