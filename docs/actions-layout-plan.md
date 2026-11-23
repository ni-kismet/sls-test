# Actions layout plan

Goal: make this repository look and work like a normal GitHub Actions repository. Actions sit in top-level folders
so other repositories can use them as `uses: rajsite/sls-test/sls-build-image@v1`, the implementation lives in
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

- [ ] L1.1 `git mv`: `.github/actions/sls-{build-image,start-server,collect-logs}` → top level; `sls/{build,image,testkit}`
  → `src/`; `sls/configs` → `src/seeds`; `scripts/ci/*`, `scripts/{Invoke-SlsBuild,Push-SlsImage,Test-NoSecret}.ps1`
  → `src/ci/`; `scripts/ci/Test-SlsActionsRun.ps1` → `tests/`.
- [ ] L1.2 Remove `sls-host-prep` (build and start call `host-prep.sh` directly; a composite action used from another
  repository can't `uses:` a sibling local action), the soak/probe tooling (`probe.yml`, `soak.yml`,
  `soak-image.yml`, `package-delete.yml`, `Get-SoakSummary.ps1`, `Test-SlsStability.ps1`), `Sync-SlsTooling.ps1`
  and `sls/SOURCE.md`. `actions-test.yml` is replaced by `test.yml` (L5).
- [ ] L1.3 Paths: actions use `$GITHUB_ACTION_PATH/../src`; scripts find `src/` from their own location.
- [ ] L1.4 Build output goes to `$SLS_OUT` (actions: `$RUNNER_TEMP/sls`, outside the action checkout, which for a
  remote caller is GitHub's download of this repository); local default stays `src/out` (git-ignored).

### L2. Password

- [ ] L2.1 Default web admin `admin` / `test`: `admin-password` defaults to `test` in `sls-build-image` and
  `sls-start-server`; `compose.yaml`, testkit and docs use it. A custom password still works at build and at start.
- [ ] L2.2 Seeding sets the requested password in the work container at start (the guest agent's runtime password
  change), so a seeded image always has `admin-password`, whatever its base had; no base credential is needed.
- [ ] L2.3 `sls-start-server` only asks for a password change when it differs from the image's (saves ~40 s).
- [ ] L2.4 Remove the `SLS_ADMIN_PASSWORD` secret from workflows, masking of the default password, and the
  `allow-new-package` push guard. The leak check keeps the license file contents, the VM password and a custom
  admin password; it ignores the default `test`.
- [ ] L2.5 Check early that the NI Web Server accepts `test` (first seed run sets it at start, ~5 min in).

### L3. Custom seeds

- [ ] L3.1 `sls-build-image` inputs `seed` (built-in name `demo`/`migration`, or a path to a `.ps1` in the caller's
  workspace) and `config-name` (tag suffix; default: the built-in name or the seed's folder name). Replaces `config`.
- [ ] L3.2 The seed path is checked (exists, parses) before any build starts.
- [ ] L3.3 `$env:SLS_TESTKIT` points at `SlsTestKit.psm1` for seed scripts; built-in seeds use it (with a relative
  fallback for local runs).
- [ ] L3.4 `tests/seed/Seed.ps1`: small custom seed (workspace, tag, file) with `-Verify`.
- [ ] L3.5 `docs/seeds.md`: contract, testkit helpers, base-once/seed-many pattern.

### L4. Inputs and tags

- [ ] L4.1 Remove `on-bugcheck` (always restart from Install), `allow-new-package` and `sls-start-server` `pull`
  (pulls when missing). Group the remaining advanced inputs in the docs.
- [ ] L4.2 Dated tags unique per build: base `<x.y.z>-<yyyyMMdd>-<HHmm>` (UTC build time), seeded
  `<x.y.z>-<yyyyMMdd>-<HHmm>-<config>` (UTC seed time), so a same-day rebuild or re-seed never overwrites a tag.
  Floating tags (`26.5`, `26.5.1`, `26.5[-.1]-<config>`) and `r<run>[-<config>]` unchanged.

### L5. Workflows (fail early, build less)

- [ ] L5.1 `ci.yml`: actionlint, PowerShell parse check of every `.ps1`/`.psm1`, shellcheck (errors) on `*.sh` and
  `src/image/bin/*`. About 1 min, on every push and PR.
- [ ] L5.2 `test.yml`:
  - `plan` job (seconds): decides `rebuild` when the push/PR changes files that end up in the base image
    (`src/build/**`, `src/image/**` except `config.Dockerfile`), when dispatched with `base: rebuild`, or when the
    reuse base is missing; otherwise reuses `ghcr.io/rajsite/sls-server-actions-test:26.5`.
  - `build` job: `sls-build-image` with `seed: tests/seed/Seed.ps1`, push to the test package (`r<run>` tags; the
    floating base tag only from `main`). Preflight (inputs, seed, KVM, disk) fails in seconds.
  - `start` job (fresh runner): `sls-start-server` from the registry by digest, `tests/Test-SlsActionsRun.ps1`
    (coverage + the seed's `-Verify`), `sls-collect-logs`.
  - Reuse path ~25 min, rebuild path ~95 min. `concurrency` per event and ref, `cancel-in-progress`.
- [ ] L5.3 `build-images.yml`: `seed:` instead of `config:`, no password secret.
- [ ] L5.4 Pin the runner label (`ubuntu-26.04`) once the workflows are green, so a future `ubuntu-latest` switch
  can't change disk layout, kernel or pwsh under the build.

### L6. Docs and release

- [ ] L6.1 README: what it is, quick start (build + seed + push; start + test), per-action inputs/outputs (main and
  advanced), custom seeds, local use, limits.
- [ ] L6.2 `docs/local.md` (compose, testkit, local builds); `docs/workflow-test-plan.md` → `docs/history/`.
- [ ] L6.3 `LICENSE` (MIT).
- [ ] L6.4 Tag `v1.0.0` and the moving `v1` once green.

### L7. Verification

- [ ] L7.1 Local: actionlint, parse check, shellcheck.
- [ ] L7.2 `test.yml` reuse run (dispatch, ~25 min): seed from the existing base with password `test`, start from
  the registry, checks green.
- [ ] L7.3 `test.yml` rebuild run (push, ~95 min): base with password `test`, unique dated tags.
- [ ] L7.4 `build-images.yml` re-seed run against the test package: green, floating tags moved, unique seeded tags.
- [ ] L7.5 After pinning the runner label: `ci.yml` and `test.yml` (reuse) green.

## Status and notes

(filled in during implementation)
