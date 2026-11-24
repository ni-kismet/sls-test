# Actions layout plan

Goal: make this repository look and work like a normal GitHub Actions repository. Actions sit in top-level folders
so other repositories can use them as `uses: ni-kismet/sls-test/sls-build-image@v1`, the implementation lives in
`src/`, workflows only test the actions (plus the manual image publish), the admin password is a plain default,
and custom seeds are supported. The repository is not renamed.

CI image builds are slow (base 60–90 min, seed 10–15 min), so the checks are ordered to fail early and the
workflows reuse an existing base whenever the base content did not change.

## Target layout

```
.github/workflows/
  ci.yml             lint on every push and PR (actionlint, PowerShell parse, shellcheck)
  test.yml           tests the actions (build or reuse base -> custom seed -> start from the registry)
  build-images.yml   publishes prebuilt images, manual only
sls-build-image/action.yml
sls-start-server/action.yml
sls-collect-logs/action.yml
src/
  build/    Build-SlsImage.ps1, stages/, guest/
  image/    Dockerfile, config.Dockerfile, start.sh, bin/, guest agent
  ci/       Build-SlsCi, Start-SlsCi, Collect-SlsLogs, Publish-SlsImages, Invoke-SlsBuild, Push-SlsImage,
            Test-NoSecret, host-prep.sh, host-facts.sh
  seeds/    demo/, migration/
  testkit/  SlsTestKit.psm1, compose.yaml, examples/
tests/
  Test-Syntax.ps1    parse check + seed contract (ci.yml, and test.yml before any build)
  Test-SlsActionsRun.ps1
  seed/Seed.ps1      custom seed fixture (proves the caller-seed path)
docs/
  seeds.md, local.md, history/workflow-test-plan.md
README.md, LICENSE
```

## Decisions

- Keep `build-images.yml` (manual) so consumers can pull prebuilt images instead of building for 60–90 min.
- This repository is the source of truth for the tooling; the sync from `mraj-sls-container` stops
  (`Sync-SlsTooling.ps1` and `sls/SOURCE.md` are removed).
- No rename now.
- `test.yml` runs on PRs and pushes to `main` that touch the actions, `src/` or `tests/`; newer runs cancel older ones.
- License: MIT.

## Checklist

### L1. Layout

- [x] L1.1 `git mv`: `.github/actions/sls-{build-image,start-server,collect-logs}` → top level; `sls/{build,image,testkit}`
  → `src/`; `sls/configs` → `src/seeds`; `scripts/ci/*`, `scripts/{Invoke-SlsBuild,Push-SlsImage,Test-NoSecret}.ps1`
  → `src/ci/`; `scripts/ci/Test-SlsActionsRun.ps1` → `tests/`.
- [x] L1.2 Remove `sls-host-prep` (build and start call `host-prep.sh` directly; a composite action used from another
  repository can't `uses:` a sibling local action), the soak/probe tooling (`probe.yml`, `soak.yml`,
  `soak-image.yml`, `package-delete.yml`, `Get-SoakSummary.ps1`, `Test-SlsStability.ps1`), `Sync-SlsTooling.ps1`
  and `sls/SOURCE.md`. `actions-test.yml` is replaced by `test.yml` (L5).
- [x] L1.3 Paths: actions use `$GITHUB_ACTION_PATH/../src`; scripts find `src/` from their own location.
- [x] L1.4 Build output goes to `$SLS_OUT` (actions: `$RUNNER_TEMP/sls`, outside the action checkout, which for a
  remote caller is GitHub's download of this repository); local default stays `src/out` (git-ignored).

### L2. Password

- [x] L2.1 Default web admin `admin` / `test`: `admin-password` defaults to `test` in `sls-build-image` and
  `sls-start-server`; `compose.yaml`, testkit and docs use it. A custom password still works at build and at start.
- [x] L2.2 Seeding sets the requested password in the work container at start (the guest agent's runtime password
  change), so a seeded image always has `admin-password`, whatever its base had; no base credential is needed.
- [x] L2.3 `sls-start-server` only asks for a password change when it differs from the image's (saves ~40 s).
- [x] L2.4 Remove the `SLS_ADMIN_PASSWORD` secret from workflows, masking of the default password, and the
  `allow-new-package` push guard. The leak check keeps the license file contents, the VM password and a custom
  admin password; it ignores the default `test`.
- [x] L2.5 Check early that the NI Web Server accepts `test` (first seed run sets it at start, ~5 min in).

### L3. Custom seeds

- [x] L3.1 `sls-build-image` inputs `seed` (built-in name `demo`/`migration`, or a path to a `.ps1` in the caller's
  workspace) and `config-name` (tag suffix; default: the built-in name or the seed's folder name). Replaces `config`.
- [x] L3.2 The seed path is checked (exists, parses) before any build starts.
- [x] L3.3 `$env:SLS_TESTKIT` points at `SlsTestKit.psm1` for seed scripts; built-in seeds use it (with a relative
  fallback for local runs).
- [x] L3.4 `tests/seed/Seed.ps1`: small custom seed (tags, file) with `-Verify`, written as another repository would.
- [x] L3.5 `docs/seeds.md`: contract, testkit helpers, base-once/seed-many pattern.

### L4. Inputs and tags

- [x] L4.1 Remove `on-bugcheck` (always restart from Install), `allow-new-package` and `sls-start-server` `pull`
  (pulls when missing). Group the remaining advanced inputs in the docs.
- [x] L4.2 Dated tags unique per build: base `<x.y.z>-<yyyyMMdd>-<HHmm>` (UTC build time), seeded
  `<x.y.z>-<yyyyMMdd>-<HHmm>-<config>` (UTC seed time), so a same-day rebuild or re-seed never overwrites a tag.
  Floating tags (`26.5`, `26.5.1`, `26.5[-.1]-<config>`) and `r<run>[-<config>]` unchanged.

### L5. Workflows (fail early, build less)

- [x] L5.1 `ci.yml`: actionlint, PowerShell parse check of every `.ps1`/`.psm1`, shellcheck (errors) on `*.sh` and
  `src/image/bin/*`. About 1 min, on every push and PR.
- [x] L5.2 `test.yml`:
  - `plan` job (seconds): runs `tests/Test-Syntax.ps1` (parse + seed contract), then decides `rebuild` when the push/PR changes files that end up in the base image
    (`src/build/**`, `src/image/**` except `config.Dockerfile`), when dispatched with `base: rebuild`, or when the
    reuse base is missing; otherwise reuses `ghcr.io/ni-kismet/sls-server-actions-test:26.5`.
  - `build` job: `sls-build-image` with `seed: tests/seed/Seed.ps1`, push to the test package (`r<run>` tags; the
    floating base tag only from `main`). Preflight (inputs, seed, KVM, disk) fails in seconds.
  - `start` job (fresh runner): `sls-start-server` from the registry by digest, `tests/Test-SlsActionsRun.ps1`
    (coverage + the seed's `-Verify`), `sls-collect-logs`.
  - Reuse path ~25 min, rebuild path ~95 min. `concurrency` per event and ref, `cancel-in-progress`.
- [x] L5.3 `build-images.yml`: `seed:` instead of `config:`, no password secret.
- [x] L5.4 Pin the runner label (`ubuntu-26.04`) once the workflows are green, so a future `ubuntu-latest` switch
  can't change disk layout, kernel or pwsh under the build.

### L6. Docs and release

- [x] L6.1 README: what it is, quick start (build + seed + push; start + test), per-action inputs/outputs (main and
  advanced), custom seeds, local use, limits.
- [x] L6.2 `docs/local.md` (compose, testkit, local builds); `docs/workflow-test-plan.md` → `docs/history/`.
- [x] L6.3 `LICENSE` (MIT).
- [x] L6.4 Tag `v1.0.0` and the moving `v1` once green.

### L7. Verification

- [x] L7.1 Local: actionlint, parse check, shellcheck.
- [x] L7.2 `test.yml` reuse run (dispatch, ~25 min): seed from the existing base with password `test`, start from
  the registry, checks green.
- [x] L7.3 `test.yml` rebuild run (push, ~95 min): base with password `test`, unique dated tags.
- [x] L7.4 `build-images.yml` re-seed run against the test package: green, floating tags moved, unique seeded tags.
- [x] L7.5 After pinning the runner label: `ci.yml` and `test.yml` (reuse) green.

## Status and notes

- L1–L5.3: done. Workflows left: `ci.yml`, `test.yml`, `build-images.yml`. `Test-SlsActionsRun.ps1` moved to
  `tests/` next to the fixture seed and `Test-Syntax.ps1`.
- L2.5: checked locally before any CI run. `sls-server-mod:26.5` started with `-AdminCredential admin/test` was
  healthy in 199 s; authenticated API call ok, wrong password 401. The NI Web Server accepts a 4-character password.
- L2.3: images carry the label `com.ni.sls.admin-password` (`test` or `custom`, never the value).
  `sls-start-server` skips the password change when the label equals the requested password; older images without
  the label always get the change (safe, ~40 s).
- L4.2: dated tag `<x.y.z>-<yyyyMMdd>-<HHmm>` (UTC) for the base and `<x.y.z>-<yyyyMMdd>-<HHmm>-<config>` for a
  seeded image; `Publish-SlsImages.ps1` works from digests and labels, so it does not depend on the tag format.
- Custom seeds: `seed` is a built-in name or a path relative to the caller's workspace. The preflight checks that
  the file exists, parses, and has the `BaseUrl`/`Credential`/`Container`/`Verify` parameters before the build.
- L7.1: actionlint, `Test-Syntax.ps1` (29 files, 3 seeds) and shellcheck (errors) clean locally.
- L7.2: run 45237608624 green in ~20 min (plan 10 s, build 13.5 min, start 6 min). Seeded tag
  `26.5.1-20261123-1824-test` is unique; start skipped the password change (label match); healthy after 201 s.
- L7.3, first try (run 45237546963, cancelled): attempt 1 installed in 34 min, then bugchecked in seal phase 2
  (nested KVM); attempt 2 froze in Windows setup with no bugcheck and only failed at the 150-minute Install limit;
  attempt 3 was installing when the run was cancelled. Fix: Install fails after 30 minutes without guest status once
  the installer has booted (normal is ~5 min), saves the screen as `sls-stall.ppm`, and logs a heartbeat every
  10 minutes so a quiet log is not mistaken for a hang.
- L5.4: `ubuntu-latest` already resolved to the `ubuntu-26.04` image, so the pin changes nothing today. The same
  commit moves to `actions/checkout@v7`, `upload-artifact@v7` and `download-artifact@v8` (Node 20 deprecation).
- L7.3: run 45273185444 green on the first attempt: build 73 min (Install 37.8, Seal 14.1, Convert 1.2, Image 2.5,
  Verify 4, then the test seed), start 9.5 min (healthy after 192 s, password change skipped by label). Base tag
  `26.5.1-20261123-2243` and seeded tag `26.5.1-20261123-2247-test` are unique. The heartbeat lines appeared during
  `install-sls`.
- L7.4: run 45273574628 green in 16 min (re-seed of `:26.5`, demo and migration in parallel). Unique tags
  `26.5.1-20261123-2154-<config>`; `26.5-<config>` and `26.5.1-<config>` moved to the new digests; the older
  same-day `26.5.1-20261123-<config>` tags are untouched.
- L7.5: `ci` and `test` green on `ubuntu-26.04`. actionlint does not know the label yet, so `.github/actionlint.yaml`
  declares it.
- L6.4: `v1.0.0` and the moving `v1` tag point at the commit that closes this plan.
