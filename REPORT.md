# AR300M parked target variants — verification report

## Scope

The parked release target-router set now visibly covers all four GL.iNet AR300M variants without changing the active shipping set. The ath79-nand rows are alternatives to the active ath79-generic rows because all four variants use the same `mips_24kc` asset name.

## Files changed (line references after edits)

- `.github/workflows/scripts/release-assets.py:50-58`: qualified AR300M target mapping in the header comment.
- `.github/workflows/scripts/release-assets.py:83-84`: parked `mips_24kc` / `ath79-nand` SDK rows for apk and ipk.
- `.github/workflows/scripts/release-assets.py:109-122`: clarified NAND profile lane and offline-bundle repoint condition.
- `.github/workflows/multi-arch-test-build.yml:75`: parked ath79-nand commented JSON PR row.
- `docs/per-arch-release-assets.md:38-56`: four-variant mapping, package arch, board identification, and Gate D/offline-bundle repoint note.

No active club row, active offline row, or Gate D CLUB list was changed.

## Baseline: unmodified tree

Command: `bash net/tollgate-wrt/test-feed-ci.sh`

```text
RC=0
OK: the club device set (a53 = MT3000/MT6000, mips_24kc = AR300M) keeps its .apk row and offline bundle
OK: control: the check refuses a club device arch whose .apk release row was removed
OK: every release-lane arch keeps an active-or-parked PR row (parking cannot hide the restore path)
OK: control: the check refuses a shipped arch with no active-or-parked PR row
OK: every parked release row is still a literal, paste-back-able 4-tuple
OK: control: the check refuses a matrix whose parked rows were deleted
OK: control: the check refuses a corrupted parked row
test-feed-ci: PASS
```

Gate D: PASS. Gate J: PASS. Gate K: PASS, including both negative controls.

Baseline JSON hashes:

- `matrix`: `06ad84718ee80a5e39f7d8970ebf8dae2b27d56ca94710de3fbe4cc2e127e0ad`
- `offline-matrix`: `ac0cb3f4e99ada3df3605bd62e0677ba0075d5d14bf0bc1e10447a01da690263`

## Post-change verification

Command: `bash net/tollgate-wrt/test-feed-ci.sh`

```text
RC=0
OK: the club device set (a53 = MT3000/MT6000, mips_24kc = AR300M) keeps its .apk row and offline bundle
OK: control: the check refuses a club device arch whose .apk release row was removed
OK: every release-lane arch keeps an active-or-parked PR row (parking cannot hide the restore path)
OK: control: the check refuses a shipped arch with no active-or-parked row in the PR workflow
OK: every parked release row is still a literal, paste-back-able 4-tuple
OK: control: the check refuses a matrix whose parked rows were deleted
OK: control: the check refuses a corrupted parked row
test-feed-ci: PASS
```

Gate D: PASS. Gate J: PASS. Gate K: PASS, including both negative controls.

## Inertness proof

Commands:

- `python3 .github/workflows/scripts/release-assets.py matrix`
- `python3 .github/workflows/scripts/release-assets.py offline-matrix`

Post-change hashes:

- `matrix`: `06ad84718ee80a5e39f7d8970ebf8dae2b27d56ca94710de3fbe4cc2e127e0ad`
- `offline-matrix`: `ac0cb3f4e99ada3df3605bd62e0677ba0075d5d14bf0bc1e10447a01da690263`

`cmp` returned success for both before/after JSON files: both outputs are byte-identical. Nothing that ships today changed.

## Adversarial Gate K self-check

A temporary copy was made with the new parked row corrupted exactly like Gate K's own negative control: one quote was removed while the trailing `),` was retained. Running the verbatim `parked_rows_check` Python body from `test-feed-ci.sh` against that copy returned exit code 1 and reported:

```text
parked row is not restorable Python: ("mips_24kc", "ath79-nand", "openwrt-25.12", "apk)  (unterminated string literal ...)
```

The same Gate K body against the clean file returned exit code 0. Result: PASS — the new rows are parsed by Gate K, not silently ignored. The temporary copy was removed.

## Commit and publication

- Implementation commit: `2312b41a05f3eddfe23cf67d450f0d58bf0422a5`
- Remote-observed branch SHA (`git ls-remote origin refs/heads/pr/ar300m-parked-nand`): `2312b41a05f3eddfe23cf67d450f0d58bf0422a5`
- PR URL: https://github.com/FreedomTechFeed/packages/pull/56

## Remaining steps

1. None after the commit, push, remote SHA confirmation, and PR creation are observed.
