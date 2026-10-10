# Fast builds — prebaked SDK builder image

Status: opt-in / **not yet enabled**. Drafted 2026-10-10.

## The problem

The PR lane (`multi-arch-test-build.yml`) and the tag lane
(`release-publish.yml`) build through `openwrt/gh-action-sdk@v11`. That action
builds a thin wrapper image `FROM $CONTAINER:$ARCH` and then, at container
runtime, runs `feeds update -a` / `make defconfig` / `feeds install` /
`make package/tollgate-wrt/compile` **inside the container**.

The SDK images are already pinned to *exact released* versions, so the ~260 MB
SDK download is gone. What remains is the **dependency-closure rebuild** —
measured ~1200 s on run 38011377543, job "Test x86_64", and ~35–42 min wall
time end to end. That is the cost this work removes.

gh-action-sdk also caches its *wrapper image* via buildx `type=gha`, but that
image only contains the SDK base + `entrypoint.sh`; the compile work happens at
`docker run` time and is not cached.

## The mechanism

gh-action-sdk's `action.yml` declares `build-args: CONTAINER ARCH`. Docker
Buildx resolves a bare `KEY` build-arg from the environment, and composite
actions inherit the caller step's `env:`. So setting, on the build step:

```yaml
env:
  CONTAINER: ghcr.io/freedomtechfeed/tollgate-sdk
  ARCH: aarch64_cortex-a53-25.12.5
```

makes gh-action-sdk build `FROM ghcr.io/freedomtechfeed/tollgate-sdk:aarch64_cortex-a53-25.12.5`
instead of the stock image — **no fork of the action required**.

## What is added

| File | Purpose |
|---|---|
| `.github/sdk-builder/Dockerfile` | `FROM openwrt/sdk:<arch>-<ver>` + rewrite feeds to the github mirrors + add the tollgate feed as a `src-link` + `feeds update` + `defconfig` + `feeds install tollgate-wrt` + `make package/tollgate-wrt/compile`. Leaving the resulting `build_dir`/`staging_dir` in the image is the cache. |
| `.github/sdk-builder/.gitignore` | ignores the runtime-staged `feed/` tree. |
| `.github/workflows/build-tollgate-sdk-image.yml` | builds & pushes one image per `(arch, sdk)` derived from `release-assets.py` (+ `x86_64/25.12.5` for the PR lane), to `ghcr.io/freedomtechfeed/tollgate-sdk:<arch>-<ver>`, with a **registry** cache (`type=registry`, option 1.2). |
| `multi-arch-test-build.yml`, `release-publish.yml` | add `CONTAINER: ${{ vars.TOLLGATE_SDK_IMAGE || 'ghcr.io/openwrt/sdk' }}` to the SDK build step. |

The image build compiles the **real** `net/tollgate-wrt` (from the checked-out
feed) so the closure it warms is exactly the package's closure, not a guessed
list of targets. At runtime the real feed is mounted at `/feed`, re-linked with
`feeds install -f`, and `make package/tollgate-wrt/compile` rebuilds only the
package itself — reusing the warm closure.

## Adoption (opt-in, safe)

`CONTAINER` falls back to `ghcr.io/openwrt/sdk` when the repository variable
`TOLLGATE_SDK_IMAGE` is unset, so **this change is a no-op until the variable is
set**. To enable:

1. Run the **Build TollGate SDK builder image** workflow (`workflow_dispatch`,
   `push` on). It also runs on `master` pushes that touch the Dockerfile or
   `net/tollgate-wrt/Makefile`, and weekly.
2. Verify both `tollgate-sdk` and `tollgate-sdk-cache` images exist under the
   org's Packages.
3. Make the `tollgate-sdk` package **public** (Settings → Packages → visibility)
   so the unauthenticated `gh-action-sdk` pull works. Otherwise add a
   `docker/login-action` step to the consuming lanes before the SDK build.
4. Set the repo variable
   `TOLLGATE_SDK_IMAGE=ghcr.io/freedomtechfeed/tollgate-sdk`.
5. Open one PR and compare the `Test <arch>` job duration against ~42 min.

## Rollback

Unset the repository variable — the lanes return to the stock image
immediately. No code change required.

## Notes / caveats

- **This Dockerfile has not been run in CI yet.** Validate per the steps above
  before enabling; the base image's layout (`USER buildbot`, `WORKDIR /builder`,
  bundled SDK) is confirmed from the published image config, but the build must
  still be exercised.
- All files here are `.github/**` / docs — **fork-local**. Per Gate L
  (`net/tollgate-wrt/UPSTREAM-MANIFEST.txt`) none of it travels to an
  `openwrt/packages` submission, so fast-builds and upstream-mergeability are
  compatible in one tree.
- Rebuild the image whenever `net/tollgate-wrt/Makefile`'s pin changes; the
  weekly schedule and the `paths:` trigger cover the pin move automatically.
