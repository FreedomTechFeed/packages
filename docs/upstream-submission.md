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
| L5 | no `upstream`-classified file *functionally* references a `fork-local` path, so the extracted submission still builds (comments are stripped first) |

L2 is the load-bearing one: **adding a file to the package directory fails the gate
until someone classifies it.** Classification is a decision, not a default, so the
split cannot drift.

Two limits worth stating plainly, so the gate is not over-trusted:

- **L1–L4 prove completeness, not correctness.** They enforce a *partition*: every file
  is classified, and `files/` and the `Makefile` carry the labels they must. They cannot
  say any other label is right — measured: relabelling `test-devendored.sh`,
  `test-feed-ci.sh` and even `UPSTREAM-MANIFEST.txt` itself as `upstream` leaves the gate
  **green**, because the manifest *is* the decision record. Correctness is a human
  decision; L5 only catches the one correctness failure that is mechanically detectable
  (a submission that would not build).
- **`files/*` is a recursive glob.** The pattern's `*` crosses `/`, so *anything* added
  under `files/` is auto-classified `upstream` without a manifest edit. That is the right
  default for an installed payload, but it means L2's "a newly added file fails until
  classified" does **not** hold inside `files/`. Committed build output under `files/` is
  caught separately by Gate A in `test-devendored.sh`.

Gate L runs from `test-feed-ci.sh`, so the existing always-on `feed-gates.yml` job
covers it — no new workflow, no `paths:` filter.

## Producing the upstream submission

1. `git ls-files net/tollgate-wrt` — take every path the manifest marks `upstream`.
   That set is the submission; nothing else is reviewed.
2. Copy just that set into a branch of a clean `openwrt/packages` checkout.
3. The `fork-local` paths (the house harness, Gate L, the manifest,
   `scripts/build-portal-bundle.sh`, `vendor.lock.json`) are simply absent — they are
   not deleted from this fork and do not need to be, because they never travel.
4. Re-check that no `upstream` file *functionally* references a `fork-local` path —
   **L5 does this mechanically**, so this step is now a review aid, not a manual grep.
   Be honest about the state today, because "comment-only" is not the same as "clean":
   the `Makefile` names **five** fork-local artifacts across **27 comment lines** —
   `test-pkg-tarball-parity.sh` ×13, `scripts/build-portal-bundle.sh` ×5,
   `vendor.lock.json` ×5, `test-devendored.sh` ×3, `.github/scripts/check-vendor-drift.sh` ×1
   (e.g. `:32`, `:140`, `:150`, `:288`, `:572`, `:873`, `:878`, `:972`, `:991`), and
   `files/uci-defaults/92-tollgate-admin-setup` names `vendor.lock.json` in a comment too.
   **None is a functional reference** (measured: 0 non-comment matches for all five paths),
   so the extracted tree still builds — but a reviewer receives 27 lines of commentary
   about a harness that is not in the submission. That is a **known, accepted
   non-conformance**, not a clean result. Decide per submission whether to strip those
   comments before sending; L5 will not force it, because L5 answers the build question,
   not the tidiness question.

## What the current split is

- **upstream**: `Makefile`, `files/**` (the rpcd + uci-defaults payload), `test.sh`,
  `test-version.sh` — both of the latter follow the `openwrt/packages` package-test
  convention and say so in their own headers.
- **fork-local**: `test-devendored.sh`, `test-feed-ci.sh`, `test-pkg-tarball-parity.sh`,
  `test-uci-defaults-order.sh`, `test-upstream-fidelity.sh`, `UPSTREAM-MANIFEST.txt`,
  `scripts/build-portal-bundle.sh`, `vendor.lock.json`.

## Why not a second, long-lived "pristine" branch?

The tempting design is two branches: a `main` that uses registry speed machinery, and a
long-lived `pristine`/`upstream` branch that is the "real" submission. It is the wrong
design, for three reasons:

1. **The split is already per-path, so a branch adds nothing.** An `openwrt/packages`
   merge touches the package directory only. Every file that must not travel already sits
   in `.github/**` or in the `fork-local` set — bytes the maintainer never sees. A branch
   would duplicate that boundary at a coarser granularity and introduce a *second* place
   where "what travels" is decided.
2. **A second branch rots because nothing exercises it.** CI runs on the fast branch. The
   pristine branch gets no builds, so it silently diverges: the Makefile changes on `main`
   and not there, a vendor pin moves, and the first exercise of the pristine branch is the
   upstream submission itself — the worst possible moment to discover it does not build.
   Here the submission is *derived* (`git ls-files` + the manifest) from the one tree CI
   actually builds, so it is exercised by every PR.
3. **Two branches double the review surface.** Every package change would need a
   cherry-pick or a merge discipline that is easy to get wrong, and a divergence between
   the branches becomes its own maintenance task.

Gate L is what makes the one-tree approach safe: it turns "which bytes travel" from a
convention into an assertion, so no second branch is needed to keep the submission honest.

**Known stale artifact.** A branch `tollgate-wrt-upstream` still exists on `origin`
(`9bd69d9`) from the earlier two-branch experiment. It is *not* part of this design and
should be deleted; nothing derives from it. Until it is removed, do not treat its
existence as evidence that a two-branch split is in use.
