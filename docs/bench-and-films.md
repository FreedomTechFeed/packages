# Bench routers and films — where to look

Validating a per-`(arch, target)` release (see [TARGETS.md](../TARGETS.md)) means
installing onto the physical bench routers; the narrated install films are
recorded against the same hardware. Both live in the
`physical-router-test-automation` (PRTA) repository:

- **Reaching a TollGate-installed box** — after install the wired LAN moves to
  `br-private` (`10.x`), so the box is **not** at its flashed LAN IP; reach it on
  the gateway's directly-connected management net:
  [RUNBOOK-bench-lab.md](https://github.com/OpenTollGate/physical-router-test-automation/blob/main/docs/RUNBOOK-bench-lab.md#reaching-a-tollgate-installed-box-post-install-address).
- **Which router is which** (fleet pair, laptop bench, farm):
  [bench-environments.md](https://github.com/OpenTollGate/physical-router-test-automation/blob/main/docs/bench-environments.md).
- **Films: where to record** (scripted vs. router-driven, and why to run
  router-driven films on the LAN-side host):
  [film-lane.md](https://github.com/OpenTollGate/physical-router-test-automation/blob/main/docs/film-lane.md#router-driven-films-where-to-record).
