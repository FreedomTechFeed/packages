# Submitting tollgate-wrt to upstream `openwrt/packages`

**Short answer to "do we need a fast registry fork AND a slow pristine fork?" — no.**

Two facts make one tree sufficient, and both are checkable:

1. **Upstream's own build already IS a container registry.** `openwrt/packages`'
   `.github/workflows/multi-arch-test-build.yml` is a 27-line stub that delegates to
   `openwrt/actions-shared-workflows`, which uses `openwrt/gh-action-sdk` — i.e. it
   pulls SDK images. A fork using the same action is *following* upstream, not
   diverging from it.
2. **An upstream PR is per-path.** Merges to `openwrt/packages` touch the package
   directory only (`net/kea/Makefile`, `net/tor/Makefile`, …). `.github/**` is never
   part of a package submission, so the fork's CI — including every speed
   optimisation — stays fork-local by construction.

So the "fast" machinery and the "upstream-mergeable" package already occupy
different bytes. What was missing is that the split was *implicit* — a convention
that can rot silently, with a rejected upstream PR as the first symptom.

## The enforced split: `UPSTREAM-MANIFEST.txt` + Gate L

`net/tollgate-wrt/UPSTREAM-MANIFEST.txt` classifies **every** tracked file under the
package directory as either:

- `upstream` — belongs in a package PR; must stay upstream-shaped (no fork URLs, no
  CI-only paths, no house-harness assumptions);
- `fork-local` — exists only for this fork's CI/release machinery; must not travel.

`net/tollgate-wrt/test-upstream-fidelity.sh` (Gate L) enforces it:

| Check | Asserts |
| --- | --- |
| L1 | the manifest exists, is well-formed, and has no stale entries |
| L2 | every tracked file under the package dir is classified **exactly once** |
| L3 | nothing under `files/` is classified `fork-local` (it is both the installed payload and the reviewed artifact) |
| L4 | the `Makefile` is classified `upstream` (the core artifact of a package PR) |

L2 is the load-bearing one: **adding a file to the package directory fails the gate
until someone classifies it.** Classification is a decision, not a default, so the
split cannot drift.

Gate L runs from `test-feed-ci.sh`, so the existing always-on `feed-gates.yml` job
covers it — no new workflow, no `paths:` filter.

## Producing the upstream submission

1. `git ls-files net/tollgate-wrt` — take every path the manifest marks `upstream`.
   That set is the submission; nothing else is reviewed.
2. Copy just that set into a branch of a clean `openwrt/packages` checkout.
3. The `fork-local` paths (the house harness, Gate L, the manifest,
   `scripts/build-portal-bundle.sh`, `vendor.lock.json`) are simply absent — they are
   not deleted from this fork and do not need to be, because they never travel.
4. Re-check that no `upstream` file references a `fork-local` path. The Makefile only
   *mentions* `vendor.lock.json` in comments today; a real reference would be a leak.

## What the current split is

- **upstream**: `Makefile`, `files/**` (the rpcd + uci-defaults payload), `test.sh`,
  `test-version.sh` — both of the latter follow the `openwrt/packages` package-test
  convention and say so in their own headers.
- **fork-local**: `test-devendored.sh`, `test-feed-ci.sh`, `test-pkg-tarball-parity.sh`,
  `test-uci-defaults-order.sh`, `test-upstream-fidelity.sh`, `UPSTREAM-MANIFEST.txt`,
  `scripts/build-portal-bundle.sh`, `vendor.lock.json`.
