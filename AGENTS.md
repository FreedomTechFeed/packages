# AGENTS.md — FreedomTechFeed/packages

Instructions for AI coding agents. The cross-repository policy (ownership
map, verification hierarchy, agent principles) is
https://github.com/OpenTollGate/physical-router-test-automation/blob/main/docs/engineering-policy.md

## Cross-Repository Engineering Ownership and Verification

**This repository is the canonical authority for shipping OpenWrt
packages**: package recipes, version and source-revision pins, package
dependencies, packaging metadata, and the published `.apk`/`.ipk` feed
artifacts and feed-publication contracts.

Neighbors — do not duplicate them:

- Implementation repositories (`OpenTollGate/tollgate-module-basic-go`,
  `tollgate-rs`, …) own their runtime code and keep reproducible
  *development* build paths only; they are not competing shipping
  authorities. A packaging fix for a TollGate package lands here, against
  the pinned source revision — never as a divergent recipe elsewhere.
- Router integration and acceptance testing of published artifacts is
  owned by `OpenTollGate/physical-router-test-automation` (PRTA), e.g. its
  `scripts/download-feed-release.sh` and
  `tests/scenarios/test_feed_package.py` consume and verify feed releases;
  they never rebuild them.
- The captive portal is `OpenTollGate/tollgate-captive-portal-site`,
  consumed at a pinned revision.

Agent rules: pin exact source revisions (never floating); every feed
release must be reproducible from its recorded pins; never modify a recipe
to make a failing test pass — fix the source or the pin; publication and
release authorization keep their existing operator approvals.
