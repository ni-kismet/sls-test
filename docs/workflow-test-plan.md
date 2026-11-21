# SystemLink Server container: GitHub Actions workflow test plan

Goal: prove the full CI loop on GitHub-hosted runners with a private GHCR registry, using an image that contains every
SystemLink service needed by the automated migration feature.

1. **build-images** (run manually) builds the SystemLink Server base image (server + Software Configuration, Test and
   Asset modules), then two seeded configuration images on top of it (`demo`, `migration`), and publishes all three to
   private `ghcr.io/rajsite/sls-server`.
2. **e2e-demo** and **e2e-migration** (separate workflows) each pull one image, start it, and run a Playwright suite
   specific to that image.

Status legend: `[ ]` open, `[x]` done, `[~]` partial / deviates (see note).

---

## 0. Decisions and assumptions

| # | Decision |
|---|----------|
| D1 | `rajsite/sls-test` is **public**; GHCR packages stay **private**. Publishing the tooling is approved (the end state is a public repo). |
| D2 | Runner: `ubuntu-latest` (public repo = 4 vCPU / 16 GB RAM, KVM available). Probe (W0.3): Ubuntu 26.04, one 150 GB disk with 88 GB free, no separate `/mnt` disk, pwsh 7.6. |
| D3 | `build-images` runs **only via `workflow_dispatch`**. No schedule. |
| D4 | One admin password for every image: repo secret `SLS_ADMIN_PASSWORD` → `SLS_BUILD_ADMIN_PASSWORD` at build. Consumers never reset it (no `SLS_ADMIN_PASSWORD` at run time). |
| D5 | Source of truth for the tooling stays `C:\dev\azdo\mraj-sls-container` (commits there stay local, not pushed). It is copied into `sls-test/sls/` by a sync script that records the source commit. Pushing `rajsite/sls-test` is required to run the workflows. |
| D6 | The base image installs **`ni-systemlink-server` + `ni-systemlink-software-config-module` + `ni-systemlink-test-module` + `ni-systemlink-asset-module`** (§2). Each comes from its own product feed; the build derives the feeds from the package names. |
| D7 | Seeded configurations: **`demo`** (existing: 100 tags + 1 file) and **`migration`** (new: every resource marked *Automated migration* in §2, plus a few *Out of scope* items as negative controls). This replaces the earlier `alarms` idea. |
| D8 | GHCR image name `ghcr.io/rajsite/sls-server` (user-scoped package, linked to the repo through the existing `org.opencontainers.image.source` label, which is derived from `git remote origin`). |
| D9 | e2e jobs test the **exact digests** of the triggering build when started by `workflow_run`; manual runs take an image input (default: floating tag). |

---

## 1. Architecture

```
workflow_dispatch
      │
build-images.yml ──────────────────────────────────────────────────────────────────────────────────────
  base (≈75–120 min)              seed [demo, migration] (matrix, ≈10–20 min each)      promote (≈1 min)
  Build-SlsImage.ps1       ──►    New-SlsConfigImage.ps1 -BaseImage <base digest>  ──►  imagetools create
  server + 3 modules              push :26.5-<cfg>-r<N>                                 :26.5  :26.5.1
  push :26.5.1-<date>-r<N>                                                              :26.5-demo
                                                                                        :26.5-migration
  artifact images.json (all digests)
───────────────────────────────────────────────────────────────────────────────────────────────────────
      │ workflow_run (success)                            │ workflow_run (success)
e2e-demo.yml ──► _sls-e2e.yml                             e2e-migration.yml ──► _sls-e2e.yml
                 (demo digest, project=demo)                                    (migration digest, project=migration)
                 pull → run → healthy → Playwright → leak-guarded artifacts
```

Image tags (all in `ghcr.io/rajsite/sls-server`):

| Tag | Written by | Mutable |
|-----|-----------|---------|
| `26.5.1-<yyyymmdd>-r<run>` | base job | no |
| `26.5-demo-r<run>`, `26.5-migration-r<run>` | seed jobs | no |
| `26.5`, `26.5.1` | promote | yes |
| `26.5-demo`, `26.5-migration` | promote | yes |

Floating tags move only after base **and** both seeds (each with its verify step) succeed.

---

## 2. Package coverage for automated migration

The current image (build `s2b`) installs only `ni-systemlink-server` (feed `ni-systemlink-server/26.5`). The
migration resources need three more products. Each has its own feed under
`https://download.ni.com/support/nipkg/products/ni-s/<product>/26.5/released` (+ `released-critical`, currently empty),
and each feed is self-contained (it also carries the shared server packages).

| SystemLink resource | Treatment | Packages (product feed) | In `s2b` |
|---|---|---|---|
| Workspaces | Automated | `ni-skyline-user-service`, `ni-skyline-security-webui` (server) | yes |
| Files | Automated | `ni-skyline-file-service`, `-file-webservice`, `-file-webui` (server) | yes |
| Test Monitor products / results / steps | Automated | `ni-skyline-test-monitor-service`, `-webservice`, `-webui`, `-common`; `ni-systemlink-postgresqldatabase-13.3` (**test-module**) | **no** |
| Feeds and hosted packages | Automated | `ni-systemlink-repository-webservice` (server, yes); `ni-skyline-repo-webui` (**software-config-module**; only *suggested* by the server) | UI **no** |
| Assets, calibration history | Automated | `ni-skyline-asset-webservice`, `ni-skyline-apm-service`, `-apm-webservice`, `ni-systemlink-apm-webui` (**asset-module**) | **no** |
| Users | Automated | `ni-skyline-user-service` (server) | yes |
| System states | Automated | `ni-systemlink-states-webservice` (**software-config-module**) | **no** |
| Systems | Manual prep | `ni-systemlink-system-webservice`, `ni-sysmgmt-*`, `ni-sysmgmt-webui` (**software-config-module**) | **no** |
| Roles, role mappings | Manual prep | `ni-skyline-user-service`, `ni-skyline-security-webui` (server) | yes |
| Tags + history, alarms, tile dashboards, web apps, notebooks, UserData, TDM, DataFinder, routines | Out of scope | Already in the server, or pulled in as module dependencies (notebook execution, JupyterHub). Nothing extra needed. | n/a |

Top-level packages to install: `ni-systemlink-server`, `ni-systemlink-software-config-module`,
`ni-systemlink-test-module`, `ni-systemlink-asset-module` (all 26.5.1.49157). The test and asset modules both depend on
the software configuration module, so listing it is only for clarity.

Effects to measure in the first full build (W4):

- **Image size vs. GHCR's 10 GB per-layer limit.** The disk layer is one file (`base.qcow2`, zstd). It was 7.67 GB
  without the modules; PostgreSQL, Python 3.8/JupyterHub and the module services will add to it. Gate: < 9.5 GB.
  Mitigations if it's over: more seal cleanup (NIPM package cache, component store), or split into two disk layers
  (base qcow2 + a modules overlay qcow2 backed by it, the same mechanism the configuration images already use).
- **Install time, boot-to-healthy time and guest RAM** with the extra services (PostgreSQL, Salt master, APM rule
  engine). Default guest RAM for consumers may need to go from 8 GB to 10 GB.
- **Licensing of the modules in an unlicensed/evaluation install.** If module APIs or UIs are blocked without a
  license, use the existing user-based license mechanism (`/licenses` mount → guest license folder): a license file
  stored as repo secret `SLS_LICENSE_FILE_B64`, written to a temp folder at job start, never uploaded and never
  baked into an image.

---

## 3. Public repository exposure

Everything printed to workflow logs and every uploaded artifact is world-readable. Rules:

| Item | Rule |
|------|------|
| `SLS_ADMIN_PASSWORD` | Only as a secret; GitHub masks it in logs. Never written to files that get uploaded. |
| VM account password (generated per build, in `credentials.json`) | Tooling emits `::add-mask::<value>` when `GITHUB_ACTIONS=true` before first use. |
| License file (only if needed, §2) | Secret `SLS_LICENSE_FILE_B64`; decoded into `$RUNNER_TEMP`, mounted read-only, deleted at job end; its folder is never staged for upload. |
| `sls/out/builds/<id>/credentials.json` | Never uploaded (explicit exclude). |
| `sls/out/builds/<id>/oem/` (holds `config.json` with the admin password; left behind if Install fails) | Never uploaded (explicit exclude). |
| Disk files (`*.qcow2`, `*.img`, `*.iso`) | Never uploaded (size and content). |
| `ca-certificates.crt` | Not uploaded (not needed in CI). |
| Playwright login (`auth.setup.ts`) | Trace/video **off** for the setup project (a trace records the login POST body). `.auth/` storage state is never uploaded. |
| Playwright tests | `trace: retain-on-failure`, `screenshot: only-on-failure`, `video: off`. Tests use the stored session, so traces don't contain the password. |
| Guest logs (`Save-SlsLogs`), `docker logs` | Uploaded only on failure, after the leak guard. |
| **Leak guard** | `scripts/Test-NoSecret.ps1` scans every staged directory before upload (plain files **and** the contents of `.zip` traces) for the admin password, the VM password and the license file contents. On a hit it deletes the staging directory and fails the step, so nothing is uploaded; it prints only the file name, never the match. |
| Artifact retention | `retention-days: 7`. |
| Fork PRs | Approval required for all outside contributors (set). Workflows never use `pull_request_target`. PR-triggered e2e jobs run only for same-repo branches (`github.event.pull_request.head.repo.full_name == github.repository`); fork PRs get no secrets. |
| Package visibility | Verified **Private** after the first push (W8.7). |

Baseline already checked: the `s2b` build logs (`build.log`, `container-*.log`, `install/**`, `seal/**`, `agent/**`,
`context.json`) contain neither password.

---

## 4. Implementation checklist

### W0. Repo bootstrap and runner probe

- [x] W0.1 Initial commit on `main`:
  - `README.md` (purpose, link to this plan)
  - `.gitignore`: `sls/out/`, `e2e/node_modules/`, `e2e/.auth/`, `e2e/playwright-report/`, `e2e/test-results/`
  - `.gitattributes`: `* text=auto`, LF for `*.sh`, `*.yml`, Dockerfiles and `sls/image/bin/*`, binary for `*.png`.
    `[~]` No `*.ps1 eol=crlf`: the source repo doesn't pin it either, so the copy keeps the same rules.
- [x] W0.2 `.github/workflows/probe.yml` (`workflow_dispatch`):
  - print `nproc`, `free -g`, `df -h / /mnt`, `ls -l /dev/kvm`, `pwsh --version`
  - print `docker info` (storage driver, data root, cgroup)
  - run `docker run --rm --device /dev/kvm alpine:3 test -c /dev/kvm`
- [x] W0.3 Push, run the probe, record results in §7. Gate: KVM usable in containers, ≥ 16 GB RAM, and `/mnt` plus freed `/` can give Docker ≥ 60 GB.
  Passed ([run 44826141525](https://github.com/rajsite/sls-test/actions/runs/44826141525)): KVM and TUN usable in
  containers, 15 GiB RAM (16 GB), 87 GB free for Docker with no prep. The runner image has changed since the plan was
  written: one 150 GB root disk, no `/mnt` temp disk.
- [x] W0.4 `.github/actions/sls-host-prep/action.yml` (composite):
  - [~] Reclaiming space is conditional: it runs only when Docker has less than `min-free-gb` (default 60). The
    probe found 87 GB free with no prep, so a normal build skips it. Order when below the minimum: move the data root
    to `/mnt/docker` if `/mnt` is a separate, larger filesystem (not the case on the current image); then remove the
    toolchains listed below; then fail if still short.
  - free `/`: remove `/usr/share/dotnet`, `/usr/local/lib/android`, `/opt/ghc`, `/usr/local/share/boost`, `/opt/hostedtoolcache/CodeQL`; `docker image prune -af`
  - move the Docker data root to `/mnt/docker` (`daemon.json`, restart docker). Fallback if `/mnt` is too small: an LVM volume over the free space of `/` and `/mnt` (as `easimon/maximize-build-space` does)
  - check `/dev/kvm` and `/dev/net/tun` from a container
  - `docker login ghcr.io` with `GITHUB_TOKEN` (input `registry-login`)
  - optional input `license-b64` → `$RUNNER_TEMP/sls-licenses/sls.lic` (folder 700, file 600), path exported as `SLS_LICENSE_DIR`
  - print a one-line host summary (CPU, RAM, Docker free GB), also to the job summary
- [x] W0.5 Make the probe call `sls-host-prep`; check Docker free space after prep. Commit and push.
  - [run 44826397722](https://github.com/rajsite/sls-test/actions/runs/44826397722) (`min-free-gb=60`): no reclaim, prep 2 s.
  - [run 44826401824](https://github.com/rajsite/sls-test/actions/runs/44826401824) (`min-free-gb=100`): reclaim path,
    87 → 112 GB free in 202 s. GHCR login, license staging (dummy value) and the `docker-free-gb` output verified.

### W1. Linux compatibility of the tooling (in `mraj-sls-container`, local commits)

The tooling has only run in pwsh on Windows against Docker Desktop. The plan assumed Linux pwsh would pass `\` through
to native commands such as `docker`. **Measured (pwsh 7.7 in WSL):** `Join-Path` converts `\` to `/`, and cmdlets
(`New-Item`, `Set-Content`, `Copy-Item`, `Test-Path`) accept raw `"$dir\sub"` strings. Only raw `\` strings passed
**directly** to a native command or a .NET API break. The host code already builds every such argument with
`Join-Path`, so the Linux changes were small.

- [x] W1.1 Install pwsh 7.5 in WSL Ubuntu (Microsoft package repo); confirm `docker` there reaches an engine with `/dev/kvm`.
  `[~]` The repo now ships pwsh 7.7.0 (installed as root via `wsl -u root`; the WSL user has no passwordless sudo).
  WSL `docker` uses the Docker Desktop engine (887 GB free); `/dev/kvm` and `/dev/net/tun` work in containers.
- [x] W1.2 Fix host-side paths passed to native commands. Known spots:
  - `build/stages/Install.ps1`: `image\bin\.`, `image\guest\.`, `build\guest\install.bat`, `build\guest\*.ps1`
  - `build/New-SlsConfigImage.ps1`: `image\config.Dockerfile`, `out\configs\<name>`
  - `build/Build-SlsImage.ps1`, `build/SlsBuild.psm1`, `build/Test-SlsRuntime.ps1`: `out\builds\…`, `testkit\SlsTestKit.psm1`, `out\runtime-tests\…`
  - `testkit/SlsTestKit.psm1`: license temp folder and `/licenses` mount path
  - Use multi-segment `Join-Path` (or `/`), which works on both OSes. Guest-side strings (`C:\…`, run inside Windows) stay as they are.
  - `[~]` Result: every spot listed above goes through `Join-Path`, which already converts the separators, so no
    change was needed. Two error messages in `Install.ps1` built paths as `"$dir\file"`; they now use `Join-Path` so
    Linux messages don't mix separators. The testkit license folder already uses `[IO.Path]::GetTempPath()`.
- [x] W1.3 Review the remaining host code for Windows-only assumptions:
  - `$env:TEMP` / `LOCALAPPDATA` (use `[IO.Path]::GetTempPath()`), `.exe` names, host `Get-CimInstance`.
    None in host code: every hit is in guest scripts, or in guest script blocks inside `Test-SlsRuntime.ps1`
    (`$env:ProgramData`, `powershell.exe`, `Get-CimInstance`).
  - CRLF in files copied into the Linux container: `*.sh`, `Dockerfile` and `image/bin/*` are already LF
    (`.gitattributes`); `Invoke-SlsHelper` strips `\r` from its scripts. **Found:** a Linux checkout would make
    `build/guest/install.bat` LF-only, which `cmd.exe` doesn't reliably support. Fixed by `*.bat text eol=crlf` in both
    repos.
  - File modes of `image/bin/*` and `image/*.sh` are 644 in git. That is fine: `image/Dockerfile` uses
    `COPY --chmod=755`, and the Install stage runs `chmod 755 /usr/local/bin/sls-*` after `docker cp`.
  - `Test-SlsDockerHost` messages no longer say WSL2 only.
- [x] W1.4 `Test-SlsDockerHost`: keep the in-container `df` (it measures the Docker data root, which is right for `/mnt/docker`); add `Build-SlsImage.ps1 -MinFreeGB` (env `SLS_BUILD_MIN_FREE_GB`).
  README build section documents Linux hosts and `-MinFreeGB`.
- [x] W1.5 Commit (no push). Runtime validation happens in W4 together with the module build.
  `mraj-sls-container` commit `9e3466f`. Smoke tests ran early from a WSL-native clone, to mimic a CI checkout
  (`install.bat` CRLF, scripts LF):
  - **Install-stage host side:** `Build-SlsImage.ps1 -To Install` was stopped once the VM started. Preflight (887 GB),
    feed and NIPM URL checks, OEM folder (`install.bat` with CRLF, guest scripts, config.json), `sls-*` tools
    (mode 755) and `/shared/guest` were all correct, and `-Cleanup` removed everything.
  - **Configuration image:** `New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name w1demo -Seed configs/demo/Seed.ps1`
    passed in 3.3 min (healthy 59 s, seal 77 s, 16.7 MB layer, verify passed). Credential from
    `SLS_BUILD_ADMIN_PASSWORD`, as in CI.
  - **Testkit:** `Start-SlsServer -LicenseFile -LicenseUser` (temp folder under `/tmp`, `/licenses` mount, user
    created, file placed), `Invoke-SlsApi`, `Invoke-SlsGuest`, `Save-SlsLogs` to a Linux folder, and `Stop-SlsServer`
    (license folder removed) all passed.
  - Not covered yet: the guest install and the Seal/Convert/Image/Verify stages on Linux; they run in W4.

### W2. CI hooks in the tooling (in `mraj-sls-container`, local commits)

- [x] W2.1 GitHub masking: when `GITHUB_ACTIONS=true`, write `::add-mask::` for the admin password (in case it was generated) and the VM password as soon as `credentials.json` is created (`Build-SlsImage.ps1`) or read (`Get-SlsImageCredential`).
- [~] W2.2 Machine-readable result: `Build-SlsImage.ps1` and `New-SlsConfigImage.ps1` write `result.json` (image, tags, image id, versions, installed product list, Windows eval expiry, sizes incl. disk layer bytes, timings) in their out dir, and append `image=`, `tags=`, `sls_full_version=` to `$GITHUB_OUTPUT` when set.
  Done differently: no new `result.json`. The existing `build.json` / `config.json` already hold the image, tags,
  versions, the products map, sizes and stage timings. CI outputs: `build_id`, `image`, `image_id`, `tags`,
  `sls_full_version`, `disk_layer_bytes`, `out_dir` (base); `image`, `image_id`, `tags`, `layer_bytes`, `out_dir` (config).
  The Windows eval expiry is in `versions.json` (`eval.expiresUtc`) and in the `com.ni.sls.windows-eval-expires` image label.- [x] W2.3 `Build-SlsImage.ps1 -ExtraTag <string[]>` and `New-SlsConfigImage.ps1 -ExtraTag` so the immutable `-r<run>` tag is applied before push.
- [x] W2.4 `New-SlsConfigImage.ps1 -LicenseFile <path[]>` (passes through to `Start-SlsServer -LicenseFile`) for seeding when modules need a license (§2).
- [~] W2.5 Confirm the image labels in CI: `org.opencontainers.image.source` = `https://github.com/rajsite/sls-test`, `revision` = sls-test commit (from `Get-SlsGitInfo`, which runs `git` in the copied tree).
  `Get-SlsGitInfo` now normalizes GitHub remotes (removes credentials and `.git`, converts SSH to `https://github.com/<owner>/<repo>`).
  This was checked with unit inputs; the label value itself is confirmed in the first CI run (W8).- [x] W2.6 Commit (no push). `mraj-sls-container` commit `1d020bc`.

### W3. Migration package coverage (in `mraj-sls-container`, local commits)

- [x] W3.1 `Build-SlsImage.ps1`: default `-Packages` = `ni-systemlink-server`, `ni-systemlink-software-config-module`, `ni-systemlink-test-module`, `ni-systemlink-asset-module`. When `-Feeds` is not given, derive `…/ni-s/<package>/<SlsVersion>/released` and `released-critical` for each top-level package (all four are products with their own feed). The preflight already checks every feed URL.
- [~] W3.2 Guest install (`Install-Sls.ps1`): one `nipkg install` with all four packages (`--include-recommended`). Record each product's installed version in `versions.json` (`products: { server, softwareConfig, test, asset }`), plus labels `com.ni.sls.products`, and add products to the build summary.
  Done with one change: `versions.json` `products` is keyed by package name (`ni-systemlink-test-module: 26.5.x`, …)
  rather than short names, so `-Packages` can be extended without a schema change. The label
  `com.ni.sls.products` = `pkg=ver,...` (build arg `SLS_PRODUCTS`).- [x] W3.3 Service coverage check, run by the build's Verify stage and by `Test-SlsRuntime.ps1`:
  - authenticated GET or POST against one endpoint per migration resource: workspaces (`niuser`), files (`nifile`), Test Monitor products / results / steps (`nitestmonitor`), feeds (`nifeed`), assets + calibration (`niapm`), users (`niuser`), states (`nisystemsstate`), systems (`nisysmgmt`)
  - exact routes are confirmed against the running image in W4.3 and recorded in this table
  - the check fails the build if any service answers 404/5xx; a license-related 403/402 is reported separately (§2 licensing)
- [x] W3.4 Seal review: make sure the module services are stopped/started cleanly by the seal and the agent (PostgreSQL, Salt master, APM). The ready condition (all automatic NI services running + HTTP 200/401) must include them.
- [x] W3.5 Disk layer gate in the Image stage: log `base.qcow2` bytes; fail when > `-MaxDiskLayerGB` (default 9.5) with a hint pointing to §2 mitigations.
- [x] W3.6 README and root `implementation-plan.md` (source repo): document the default products and how to build server-only (`-Packages ni-systemlink-server`).
- [x] W3.7 Commit (no push). `mraj-sls-container` commit `bf54851`.

### W4. Full local build on Linux (WSL), modules included

> **Paused here (status and resume steps: §10 "W4 (in progress)").** Install, Seal, Convert and Image passed for
> `wsl-mod1`; Verify fails on Test Monitor 503/504 (still starting), and the runtime image bugchecks with dockur's
> default Hyper-V enlightenments. Next: W4.1a–W4.1c, then resume `-From Image`.

- [~] W4.1 In WSL pwsh: `Build-SlsImage.ps1 -Ram 12G -Cpu 4 -BuildId wsl-mod1` (Linux paths and module install, at CI-like CPU count). Record install time, total time, disk layer and image size in §7.
  - Install 26.4 min, Seal 11.8 min (after fixes), Convert 0.5 min, Image 1.9 min; Verify failed (W4.1c). Fixes so far in `mraj-sls-container` `218b025` (build VM `HV=N`, panic detection, `/oem` via `docker cp`) and `6b928cc` (seal `mongod --repair`, crash dump purge).
  - [ ] W4.1a Runtime image: `ENV HV=N` in `image/Dockerfile` (override `-e HV=Y`); `start.sh` prepends `-action panic=pause` to `ARGUMENTS` and starts `sls-panic-watch` in the background; `healthcheck.sh` fails when `/storage/sls-panic.txt` exists. Document in README / root `implementation-plan.md`.
  - [ ] W4.1b `Test-SlsServiceCoverage -WaitSec <n>`: retry rows with status 0/502/503/504 until the deadline (Test Monitor answered 200 about 215 s after start, 504 at 192 s). Use it in `build/stages/Verify.ps1` and `build/Test-SlsRuntime.ps1` (about 300 s).
  - [ ] W4.1c Commit W4.1a/b locally; sync `~/sls`; resume `-BuildId wsl-mod1 -From Image` (rebuilds the small layers on the kept disk layer image, then Verify).
- [x] W4.2 If the disk layer gate fails: apply the §2 mitigations (seal cleanup first, two-layer split if still over) and rebuild. Not needed: `base.qcow2` 9.23 GB, under the 9.5 GB gate (only 0.27 GB of headroom, §8).
- [ ] W4.3 Boot the image; confirm every module UI page loads (Test Monitor, Assets, Package Repository, Systems, States) and the §W3.3 endpoints answer. Record boot-to-healthy time and guest RAM use (8 GB vs. 10 GB). Partial: all W3.3 routes confirmed in the failed Verify (below); Test Monitor 200 once started; boot to healthy about 180–215 s at 8 GB.
- [ ] W4.4 Licensing check: with no license file, do the module APIs/UIs work (evaluation), or are they blocked? Record the outcome. If blocked: get a user-based license file, store it as `SLS_LICENSE_FILE_B64`, and re-check with `-LicenseFile`. Early signal: no 402/403 from any module API without a license.
- [ ] W4.5 `Test-SlsRuntime.ps1` and `testkit/examples/Test-SlsServer.ps1` in WSL against the new image: green.
- [ ] W4.6 Re-run `Test-SlsRuntime.ps1` once from Windows pwsh against the same image (no regression on Windows).
- [~] W4.7 Commit any fixes (no push). `218b025`, `6b928cc` committed locally; W4.1a/b pending.

### W5. Seed configurations (in `mraj-sls-container`, local commits)

- [ ] W5.1 `configs/demo`: re-verify against the module image (`New-SlsConfigImage.ps1 -Name demo`).
- [ ] W5.2 Confirm the APIs for the migration seed against the W4 image (request shapes, required fields):
  - workspaces: `POST /niuser/v1/workspaces`
  - users: what "user data" the user service holds on SLS (local/Windows users vs. created users); seed what the API allows
  - files with workspace + metadata
  - Test Monitor: `POST /nitestmonitor/v2/products`, `/results` (status, partNumber, fileIds), `/steps` (nested)
  - feeds: `POST /nifeed/v1/feeds`, package upload to a feed
  - assets: `POST /niapm/v1/assets`, calibration history entries (operator)
  - system states: `POST /nisystemsstate/v1/states`
- [ ] W5.3 `configs/migration/Seed.ps1` (same contract as `configs/demo/Seed.ps1`: create without `-Verify`, check with `-Verify`). Data, all names prefixed `mig-`:
  - **Workspaces**: `mig-ws-a`, `mig-ws-b`
  - **Files**: 4 files across both workspaces with custom properties; 2 are attached to test results
  - **Test Monitor**: 2 products (`MIG-PN-100`, `MIG-PN-200`) with properties; 12 results across both products and workspaces:
    - 8 terminal (`PASSED`/`FAILED`/`ERRORED`)
    - 2 non-terminal (`RUNNING`)
    - 2 custom status
    - each result has 2–4 steps, including nested steps with inputs/outputs/measurement data; 2 results reference the files above
  - **Feeds**: feed `mig-feed` in `mig-ws-a` with one hosted package. Build a minimal `.nipkg` with `nipkg pack` inside the guest (via `Invoke-SlsGuest`), then upload it.
  - **Assets**: 3 manually created assets (one per workspace + one in Default), each with 2 calibration history entries including an operator name
  - **Users**: the supported user data per W5.2
  - **System states**: 2 state definitions (one per workspace) referencing `mig-feed` and its package
  - **Out-of-scope negative controls** (seeded so migration tests can assert they are *not* transferred): 5 tags `mig.tag.*` with values, 1 alarm instance `mig-alarm-1`, 1 UserData entry
  - **Not seeded**: systems (manual preparation; no managed systems in a container), roles and role mappings (manual preparation)
  - `-Verify` checks counts per resource and the relationships (result → product, result → steps, result → files, state → feed).
- [ ] W5.4 Build `sls-server:26.5-migration` locally from the W4 image; verify a fresh container from it. Record layer size and time.
- [ ] W5.5 Write a manifest `configs/migration/manifest.json` (names, counts and relationships) used by both `-Verify` and the Playwright suite, so expected values live in one place.
- [ ] W5.6 Commit (no push).

### W6. Tooling sync and leak guard in `sls-test`

- [ ] W6.1 `scripts/Sync-SlsTooling.ps1 -Source C:\dev\azdo\mraj-sls-container`:
  - refuses a dirty source tree
  - mirrors `build/`, `image/`, `testkit/`, `configs/` into `sls/` and deletes removed files; never copies `out/`
  - writes `sls/SOURCE.md` (source repo, commit, date)
- [ ] W6.2 `scripts/Test-NoSecret.ps1 -Path <dir> [-Secret <string[]>]`:
  - default secrets: `$env:SLS_ADMIN_PASSWORD`, passwords found in `sls/out/builds/*/credentials.json`, decoded `SLS_LICENSE_FILE_B64`
  - scans text files and expanded `.zip` entries; on a hit prints only the file name, deletes the path, exits 1
  - local test with a planted fake secret in a plain file and inside a zip
- [ ] W6.3 `scripts/Push-SlsImage.ps1 -Image <ref> -Tag <tag[]>`: tags, pushes with up to 3 retries (backoff), prints and outputs `repo@sha256:…`.
- [ ] W6.4 `.github/actions/sls-upload-logs/action.yml`: stage the given paths with excludes (`credentials.json`, `oem/`, `ca-certificates.crt`, `*.qcow2`, `*.img`, `*.iso`, `.auth/`, license folder) → `Test-NoSecret.ps1` → `actions/upload-artifact` (`retention-days: 7`).
- [ ] W6.5 Run the sync, commit `sls/` and the scripts, push.

### W7. Playwright suites (in `sls-test/e2e`, developed locally)

- [ ] W7.1 `e2e/package.json` (`@playwright/test` pinned), `tsconfig.json`, lockfile.
- [ ] W7.2 `playwright.config.ts`:
  - `baseURL` from `SLS_BASE_URL` (default `http://localhost:8080`)
  - projects: `setup` (`auth.setup.ts`, trace/video off), `demo` (`tests/demo/**`), `migration` (`tests/migration/**`); both depend on `setup` and use `.auth/admin.json`
  - `trace: 'retain-on-failure'`, `screenshot: 'only-on-failure'`, `video: 'off'`, `retries: 1` in CI
  - reporters: `list`, `html` (`open: 'never'`), `github`, `junit` (`results.xml`)
  - timeouts sized for a cold SystemLink UI (first page load 10–20 s)
- [ ] W7.3 `tests/auth.setup.ts`: open `/#/login`, fill `SLS_USER` (default `admin`) / `SLS_PASSWORD`, submit, wait until the URL leaves the login route, save the storage state. Selectors confirmed against the local image.
- [ ] W7.4 `tests/demo/` (image `26.5-demo`):
  - `tags.spec.ts`: Tag Viewer finds `demo.line1.*` → 10 rows; `demo.line1.sensor001` shows `1.25`; `demo.line10.sensor100` shows `100.25`
  - `files.spec.ts`: Files page lists `sls-demo.txt`
  - `api.spec.ts`: through the authenticated `request` fixture, `nitag` reports 100 `demo.*` tags
  - `isolation.spec.ts`: none of the `mig-*` data exists
- [ ] W7.5 `tests/migration/` (image `26.5-migration`). Expected values come from `sls/configs/migration/manifest.json`:
  - `workspaces.spec.ts`: Workspaces page lists `mig-ws-a`, `mig-ws-b`
  - `testmonitor.spec.ts`: Products grid shows both part numbers; Results grid filtered to `MIG-PN-100` shows the expected count and statuses; a result's detail shows its steps (nested) and attached file
  - `assets.spec.ts`: Asset grid shows the 3 assets; calibration history of one asset shows 2 entries with the operator
  - `feeds.spec.ts`: Package Repository shows `mig-feed` with its package
  - `states.spec.ts`: States page lists both state definitions in their workspaces
  - `files.spec.ts`: Files page lists the 4 files with workspace and custom properties
  - `api.spec.ts`: API counts and relationships for every resource (backs up each UI check)
  - `isolation.spec.ts`: no `demo.*` tags and no `sls-demo.txt`
- [ ] W7.6 `e2e/README.md`: running locally (`docker run … -p 8080:80 sls-server:26.5-migration`, password via `Get-SlsImageCredential`), choosing a project, updating selectors.
- [ ] W7.7 Run both suites locally against both local images: green. Also run each suite against the *other* image to confirm the isolation tests fail there. Commit and push.

### W8. `build-images.yml`

- [ ] W8.1 Trigger: `workflow_dispatch` only. Inputs:
  - `sls_version` (default `26.5`)
  - `packages` (default the four products from D6)
  - `configs` (default `demo,migration`)
  - `ram` (default `12G`), `cpu` (default `4`)
  - `promote` (bool, default `true`)
- [ ] W8.2 Top level: `permissions: { contents: read, packages: write }`; `concurrency: build-images` (no parallel builds); env `REPO=ghcr.io/rajsite/sls-server`.
- [ ] W8.3 Job `matrix`: turns the `configs` CSV into a JSON matrix output.
- [ ] W8.4 Job `base` (`timeout-minutes: 300`):
  1. checkout; `sls-host-prep`
  2. `Build-SlsImage.ps1 -SlsVersion … -Packages … -Repository $REPO -BuildId gh-${{ github.run_id }} -Ram … -Cpu … -ExtraTag <full>-<date>-r${{ github.run_number }}` with `SLS_BUILD_ADMIN_PASSWORD` from the secret
  3. `Push-SlsImage.ps1` with only the immutable tag; outputs `image` (`$REPO@sha256:…`) and `full_version`
  4. `if: always()`: `sls-upload-logs` for `sls/out/builds/gh-<run_id>` (artifact `base-logs`)
- [ ] W8.5 Job `seed` (`needs: [matrix, base]`, `fail-fast: false`, `timeout-minutes: 75`):
  1. checkout; `sls-host-prep` (with the license if configured); `docker pull <base digest>`
  2. `New-SlsConfigImage.ps1 -BaseImage <digest> -Name <cfg> -Seed sls/configs/<cfg>/Seed.ps1 -ExtraTag 26.5-<cfg>-r<run>` with `SLS_BUILD_ADMIN_PASSWORD` (the base credential source on a fresh runner)
  3. push; output the digest; write `seed-<cfg>.json` (`{config, image}`) as an artifact
  4. `sls-upload-logs` (artifact `seed-<cfg>-logs`)
- [ ] W8.6 Job `promote` (`needs: [base, seed]`, `if: inputs.promote`, no prep):
  1. `docker login`
  2. `docker buildx imagetools create -t $REPO:26.5 -t $REPO:<x.y.z> <base digest>`; same for `26.5-<cfg>`
  3. upload `images.json` (`{base, demo, migration}` digests + tags) as artifact `images`
  4. job summary: tags, digests, products and versions, sizes, timings, Windows eval expiry
- [ ] W8.7 First run with base only (`configs: ''`, `promote: false`): fix failures; record timings in §7. Then in the package settings: visibility **Private**, "Manage Actions access" lists `sls-test`, repo link shown.
- [ ] W8.8 Full run (base + both seeds + promote): green; floating tags point at the new digests (`docker buildx imagetools inspect`).

### W9. e2e workflows

- [ ] W9.1 `.github/workflows/_sls-e2e.yml` (`workflow_call`):
  - inputs `image`, `project`, `ram` (default from W4.3, 8G or 10G), `cpu` (default `4`); secrets `SLS_ADMIN_PASSWORD`, optional `SLS_LICENSE_FILE_B64`
  - `permissions: { contents: read, packages: read }`; `timeout-minutes: 45`
  - Steps:
    1. checkout; `sls-host-prep`; `docker pull <image>` (timed)
    2. `docker run -d --name sls --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --stop-timeout 150 -e RAM_SIZE -e CPU_CORES -p 8080:80 [-v $SLS_LICENSE_DIR:/licenses:ro] <image>` (no `SLS_CONFIG`, no `SLS_ADMIN_PASSWORD`)
    3. wait until healthy (`docker inspect -f '{{.State.Health.Status}}'`, 15 min limit; print the `docker logs` tail on timeout)
    4. `actions/setup-node` (cache `e2e/package-lock.json`); `npm ci`; `npx playwright install --with-deps chromium`
    5. `npx playwright test --project <project>` with `SLS_BASE_URL`, `SLS_USER=admin`, `SLS_PASSWORD`
    6. `if: always()`: `sls-upload-logs` with `playwright-report/`, `test-results/`, `results.xml` (artifact `e2e-<project>-report`)
    7. `if: failure()`: `Save-SlsLogs` + `docker logs` → `sls-upload-logs` (artifact `e2e-<project>-server-logs`)
    8. `if: always()`: `docker stop sls`
- [ ] W9.2 `e2e-demo.yml` and `e2e-migration.yml` (thin callers). Triggers:
  - `workflow_run: { workflows: [build-images], types: [completed] }`, job `if: conclusion == 'success'`; the image comes from the triggering run's `images` artifact (`actions/download-artifact` with `run-id` + `github-token`)
  - `workflow_dispatch` with input `image` (default `ghcr.io/rajsite/sls-server:26.5-demo` / `:26.5-migration`)
  - `pull_request` on `e2e/**` and the workflow files, same-repo branches only, using the floating tag
- [ ] W9.3 Dispatch each e2e workflow manually against the floating tags: green.
- [ ] W9.4 Run `build-images` again (full) and confirm both e2e workflows start automatically and test the new digests.
- [ ] W9.5 Negative check: dispatch `e2e-migration` with the demo image → migration and isolation tests fail; the report artifact uploads and passes the leak guard.

### W10. Wrap-up

- [ ] W10.1 Audit the artifacts of one full run: download all, run `Test-NoSecret.ps1` locally against them, inspect a failure trace by hand.
- [ ] W10.2 Fill in §7 (timings, sizes, minutes used, licensing outcome, endpoint table) and §8.
- [ ] W10.3 Root `README.md`: what the workflows do, how to dispatch them, how to use the images locally (`docker login ghcr.io` with a PAT that has `read:packages`), the products in the image.
- [ ] W10.4 Sync final tooling changes (W6.5), commit, push.

---

## 5. Workflow sketches

### build-images.yml (shape)

```yaml
name: build-images
on:
  workflow_dispatch:
    inputs:
      sls_version: { type: string, default: '26.5' }
      packages:    { type: string, default: 'ni-systemlink-server,ni-systemlink-software-config-module,ni-systemlink-test-module,ni-systemlink-asset-module' }
      configs:     { type: string, default: 'demo,migration' }
      ram:         { type: string, default: '12G' }
      cpu:         { type: string, default: '4' }
      promote:     { type: boolean, default: true }
permissions: { contents: read, packages: write }
concurrency: build-images
env:
  REPO: ghcr.io/rajsite/sls-server
jobs:
  matrix:
    runs-on: ubuntu-latest
    outputs: { configs: '${{ steps.m.outputs.configs }}' }
    steps:
      - id: m
        shell: pwsh
        run: '"configs=$((''${{ inputs.configs }}'' -split '','' | Where-Object { $_ } | ConvertTo-Json -AsArray -Compress))" >> $env:GITHUB_OUTPUT'
  base:
    runs-on: ubuntu-latest
    timeout-minutes: 300
    outputs:
      image: ${{ steps.push.outputs.image }}
      full_version: ${{ steps.build.outputs.sls_full_version }}
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/sls-host-prep
      - id: build
        shell: pwsh
        env: { SLS_BUILD_ADMIN_PASSWORD: '${{ secrets.SLS_ADMIN_PASSWORD }}' }
        run: >-
          ./sls/build/Build-SlsImage.ps1 -SlsVersion ${{ inputs.sls_version }} -Packages ('${{ inputs.packages }}' -split ',')
          -Repository $env:REPO -BuildId gh-${{ github.run_id }} -Ram ${{ inputs.ram }} -Cpu ${{ inputs.cpu }}
      - id: push
        shell: pwsh
        run: ./scripts/Push-SlsImage.ps1 -Image '${{ steps.build.outputs.image }}' -Tag '<full>-<date>-r${{ github.run_number }}'
      - if: always()
        uses: ./.github/actions/sls-upload-logs
        with: { name: base-logs, path: 'sls/out/builds/gh-${{ github.run_id }}' }
  seed:
    needs: [matrix, base]
    if: needs.matrix.outputs.configs != '[]'
    strategy:
      fail-fast: false
      matrix: { config: '${{ fromJSON(needs.matrix.outputs.configs) }}' }
    runs-on: ubuntu-latest
    timeout-minutes: 75
    steps: [ prep, pull base digest, New-SlsConfigImage.ps1, push, seed-<cfg>.json artifact, logs ]
  promote:
    needs: [base, seed]
    if: inputs.promote
    runs-on: ubuntu-latest
    steps: [ login, imagetools create (floating tags), images.json artifact, job summary ]
```

### e2e-migration.yml (shape; e2e-demo.yml is the same with `demo`)

```yaml
name: e2e-migration
on:
  workflow_run: { workflows: [build-images], types: [completed] }
  workflow_dispatch:
    inputs: { image: { type: string, default: 'ghcr.io/rajsite/sls-server:26.5-migration' } }
  pull_request:
    paths: ['e2e/**', 'sls/configs/migration/**', '.github/workflows/e2e-migration.yml', '.github/workflows/_sls-e2e.yml']
jobs:
  resolve:
    if: >-
      (github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'success') &&
      (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)
    runs-on: ubuntu-latest
    permissions: { actions: read }
    outputs: { image: '${{ steps.r.outputs.image }}' }
    steps: [ workflow_run: download the `images` artifact of the triggering run and pick .migration; otherwise the input or floating tag ]
  e2e:
    needs: resolve
    uses: ./.github/workflows/_sls-e2e.yml
    with: { image: '${{ needs.resolve.outputs.image }}', project: migration }
    secrets:
      SLS_ADMIN_PASSWORD: '${{ secrets.SLS_ADMIN_PASSWORD }}'
      SLS_LICENSE_FILE_B64: '${{ secrets.SLS_LICENSE_FILE_B64 }}'
    permissions: { contents: read, packages: read }
```

---

## 6. Files added to `sls-test`

```
README.md
.gitignore, .gitattributes
docs/workflow-test-plan.md                  (this file)
sls/                                        tooling copy (build/ image/ testkit/ configs/) + SOURCE.md
scripts/Sync-SlsTooling.ps1
scripts/Test-NoSecret.ps1
scripts/Push-SlsImage.ps1
.github/actions/sls-host-prep/action.yml
.github/actions/sls-upload-logs/action.yml
.github/workflows/probe.yml
.github/workflows/build-images.yml
.github/workflows/_sls-e2e.yml
.github/workflows/e2e-demo.yml
.github/workflows/e2e-migration.yml
e2e/package.json, package-lock.json, tsconfig.json, playwright.config.ts, README.md
e2e/tests/auth.setup.ts
e2e/tests/demo/{tags,files,api,isolation}.spec.ts
e2e/tests/migration/{workspaces,testmonitor,assets,feeds,states,files,api,isolation}.spec.ts
```

---

## 7. Results (filled in during implementation)

| Item | Value |
|------|-------|
| Probe: CPU / RAM / `/` free / `/mnt` free / KVM | 4 vCPU / 15 GiB (+3 GB swap file) / 88 GB of 145 GB / no separate `/mnt` / KVM + TUN usable in containers. Ubuntu 26.04.1, kernel 7.0 azure, Docker 29.4.2 (overlayfs, cgroup v2), pwsh 7.6.10 |
| Docker free after host prep | 87 GB with no reclaim (2 s); 112 GB with reclaim (202 s) |
| Products and versions installed | ni-systemlink-server, -software-config-module, -test-module, -asset-module 26.5.1.49157-0+f5; NIPM 26.8.0.49285; Windows Server 2022 build 20348.587 (eval expires 2027-05-19) |
| Base build time: WSL (4 vCPU) / GitHub | WSL `wsl-mod1` (4 cores / 12 GB VM): Install 26.4 min, Seal 11.8 min, Convert 0.5 min, Image 1.9 min (+ Verify ≈3–5 min); end-to-end time not yet measured in one run (resumed several times) / GitHub: W8 |
| Disk layer (`base.qcow2`) size, with modules | 9.23 GB (gate 9.5 GB); `data.img` allocated 20.35 GB after the seal |
| Image size, base / demo / migration layers | `sls-server-mod:26.5` 19.40 GB (build log; `docker images` 20.8 GB) / W5 / W5 |
| Boot to healthy, guest RAM used | 8 GB guest: healthy about 180–190 s, Test Monitor 200 at about 215 s (504 at 192 s); RAM use not yet measured |
| Module licensing outcome (unlicensed / license file needed) | Early: no 402/403 from any module API without a license; UI check pending (W4.4) |
| Coverage endpoints (resource → route → status) | workspaces `GET niuser/v1/workspaces` 200; users `POST niuser/v1/users/query` 200; files `GET nifile/v1/service-groups/Default/files` 200; Test Monitor `POST nitestmonitor/v2/query-products` / `query-results` / `query-steps` 503 at 130 s, 200 at 215 s; feeds `GET nirepo/v1/feeds` 200; assets `POST niapm/v1/query-assets` 200; states `GET nisystemsstate/v1/states` 200; systems `POST nisysmgmt/v1/query-systems` 200 |
| Base push time | |
| Seed job time (demo / migration) | |
| e2e job time (pull / healthy / tests) | |
| Actions minutes per full run | |

---

## 8. Risks and open points

| Risk | Mitigation |
|------|------------|
| Disk layer with modules > GHCR 10 GB layer limit | Gate in the Image stage (W3.5); more seal cleanup; two-layer split (base + modules overlay qcow2). W4: 9.23 GB, only 0.27 GB under the gate; a module update could exceed it |
| Windows guest bugchecks on nested KVM (stop 0x4A) with dockur's Hyper-V enlightenments | Seen on the WSL2 engine (AMD host) in the build seal and at run time (about 500 s after start); GitHub runners are also nested (Azure). Build VMs use `HV=N` (done); runtime image `HV=N` in W4.1a. QEMU `panic=pause` + `sls-panic-watch` make a crash visible instead of a silent exit 0 |
| Module services start after "healthy" | Test Monitor answers 503/504 for about 30 s after healthy; coverage checks and e2e tests wait for it (W4.1b; e2e: wait on a module API before the tests) |
| Modules blocked without a license | Checked in W4.4; user-based license file via secret and `/licenses` mount (never baked in, never uploaded) |
| Docker can't get ≥ 60 GB on the hosted runner | Probe: 87 GB free with no prep; `sls-host-prep` reclaims to 112 GB when needed (W0.5). The `/mnt` data root and LVM fallbacks remain for other runner images. Tune `-MinFreeGB` after measuring the real peak (W4) |
| 16 GB host RAM with a 12 GB build VM plus more services | `-Ram 10G` for the build if the runner swaps or the OOM killer fires; consumer RAM chosen in W4.3 |
| Build time on 4 vCPU with modules | Measured in W4.1; job timeout 300 min (hosted limit 6 h) |
| Large-layer push to GHCR stalls | Push retries (W6.3); measured in W8.7 |
| ≈8–10 GB pull in every e2e job | Accepted for the test; later: larger or self-hosted runners with a warm image cache |
| A module service stops by design or starts late, delaying or blocking ready | Agent waits for NI automatic services with a 180 s grace after the core ones; laggards are logged in `ready.json` (W3.4) |
| Linux path bugs beyond the known list | Full WSL build (W4) before any GitHub run |
| Seed APIs differ from expectations (users, feed upload, states) | Confirmed in W5.2 before writing the seed; anything unsupported is recorded and left out |
| UI selectors brittle across SystemLink versions | Prefer roles/labels/text; API specs back up each UI assertion; expected data from one manifest |
| `workflow_run` only uses workflow files on the default branch | Develop the e2e callers with `workflow_dispatch` first; merge to `main` before relying on `workflow_run` |
| Windows evaluation expiry (180 days) | Expiry is in the image labels and the job summary; rebuild manually before it lapses (no schedule, D3) |
| GHCR storage (≈8–10 GB per base build) | Keep recent versions only (follow-up) |

## 9. Follow-ups (out of scope)

- Retention job for GHCR versions.
- Larger or self-hosted runners with a warm image cache to cut the per-job pull.
- A second source SLS version (e.g. an older release) to exercise migration from more than one source version.
- Moving the tooling's source of truth to a public repo and consuming it as a submodule or release instead of a copy.
- Azure DevOps + JFrog version of the same flow (root `implementation-plan.md` F1–F6 in `mraj-sls-container`).
- Pin the runner label (for example `ubuntu-26.04`) once the workflows are green, so a future `ubuntu-latest` switch
  can't change disk layout, kernel or pwsh under the build (§10, W0).

## 10. Implementation notes and considerations (log)

Notes recorded during implementation that affect later steps.

**W0 (runner, host prep)**

- The hosted runner changed since planning: `ubuntu-latest` is Ubuntu 26.04 with one 150 GB root disk (88 GB free) and
  no `/mnt` temp disk. Moving the data root isn't needed; `sls-host-prep` keeps that branch only for runner images
  that have a separate, larger `/mnt`.
- Space reclaim (toolchain removal) costs about 3.4 min and gives about 25 GB. It runs only below `min-free-gb`
  (default 60). If W4 shows the peak build need is above about 85 GB, raise `min-free-gb` in `build-images` and accept
  the 3.4 min.
- RAM: 15 GiB plus a 3 GB swap file. The planned `-Ram 12G` build VM leaves about 3 GiB for the host, Docker and
  pwsh; W4.1 should watch for swapping (fallback `-Ram 10G`, §8).
- pwsh versions differ: runner 7.6.10, WSL 7.7.0, Windows dev box 7.5.4. The tooling requires 7.2+; nothing
  version-specific found.
- `GITHUB_TOKEN` login to ghcr.io works with `packages: read`. Pushing needs `packages: write` in `build-images` (W8).
- The dummy license in `probe.yml` (base64 of `probe-dummy-license`) is not a secret. It only exercises staging; real
  licenses come from the `SLS_LICENSE_FILE_B64` secret.

**W1 (Linux tooling)**

- Linux pwsh normalizes `\` in `Join-Path` and cmdlets. Rule for new host code: build paths with `Join-Path` (or
  `/`); never give raw `"$dir\x"` strings to native commands or .NET APIs. A review check for W2+ changes.
- `*.bat` must stay CRLF on Linux checkouts (`.gitattributes` in both repos). The W6 sync must keep that attribute
  in `sls-test/.gitattributes`.
- W6.1 consideration: sync from the committed tree (`git archive HEAD` of the needed folders) rather than the Windows
  working tree. It copies only committed content (no `out/`, no uncommitted edits), avoids Windows autocrlf working
  copies, and makes `SOURCE.md`'s commit exact.
- WSL setup for W4: pwsh is installed system-wide. Build from a WSL-native clone (`git clone /mnt/c/dev/azdo/mraj-sls-container ~/sls`)
  so the checkout matches CI; a build from `/mnt/c` would use the Windows working copy and slower 9p bind mounts.
- Not yet validated on Linux: the guest install and the Seal/Convert/Image/Verify stages (W4).

**W2 (CI hooks), `mraj-sls-container` `1d020bc`**

- Masking writes `::add-mask::` straight to the console (`Register-SlsSecret`), never through `Write-SlsLog`, so
  secrets never reach `build.log`. It is a no-op outside GitHub Actions. Masks are applied again on every run,
  including a `-From` resume.
- `-ExtraTag` takes a bare tag (`26.5-r123` → `<repo>:26.5-r123`) or a full reference (anything with `/` or `:`), so
  CI can tag straight into `ghcr.io/<owner>/...` without a separate `docker tag` step.
- License removal on seal: the agent appends every license item it places to `C:\sls\runtime-placed.txt`
  (`user:<name>`, `file:<path>`). `Seal-Vm` (both Light and full) removes those files, the user and its profile, then
  deletes the list. Integration test on `sls-server:26.5` (new guest scripts bind-mounted): the file and user were
  placed, and both were gone after `Seal-Vm -Phase 1 -Light`. A config image seeded with `-LicenseFile` therefore
  doesn't carry the license.
- `-MaxDiskLayerGB` (W3.5) landed in this commit together with the other new build parameters.

**W3 (migration coverage), `mraj-sls-container` `bf54851`**

- The default build installs all four products; `-Packages ni-systemlink-server` keeps a server-only build (feeds
  derived the same way). Explicit `-Feeds` still override the derivation.
- Coverage check (`Test-SlsServiceCoverage` in the testkit): each row is `ok` (2xx), `license` (402/403) or `failed`.
  Strictness: the build's Verify stage fails only when all three modules are in the package list, and
  `Test-SlsRuntime` is strict only when the image's `com.ni.sls.products` label lists the test and asset modules.
  Server-only images log the check and pass.
- Routes confirmed on the server-only `s2b` image: workspaces, users and files (200). Test Monitor, assets,
  states and systems return 404 there, as expected without modules. Feeds returned 404 on `nifeed/v1/feeds`
  and was changed to `nirepo/v1/feeds` (to confirm in W4.3).
- Agent ready condition: it now also waits for every automatic service whose binary is under `\National Instruments\`
  (computed once at agent start), with a 180 s grace after the core services. A module service that stops by design
  (for example a run-once service) doesn't block ready; it is logged and listed in `ready.json` `servicesNotRunning`.
- Seal phase 2 stops every running NI-path service, and waits for `postgres` / `pg_ctl` processes before shutdown so
  the database is flushed cleanly into the image.

**W4 (in progress; paused at W4.1), `mraj-sls-container` `218b025`, `6b928cc`**

Status at the pause:

- Build `wsl-mod1` (WSL clone `~/sls` at `6b928cc`, `-Ram 12G -Cpu 4 -Repository sls-server-mod`): Install, Seal,
  Convert and Image passed; Verify failed on Test Monitor (503 at 130 s after start). Image `sls-server-mod:26.5`
  (= `:26.5.1-20261121`) exists but still has the old runtime defaults (Hyper-V enlightenments on).
- Kept for the resume: the stopped container `sls-build-wsl-mod1` and volumes `sls-build-wsl-mod1-{storage,shared,images}`
  (the build container was recreated by hand during diagnosis with `HV=N` and `-action panic=none`, without `/oem`),
  the disk layer image `sls-server-disk:wsl-mod1`, and `~/sls/out/builds/wsl-mod1` (`context.json`, `build.log`,
  `credentials.json` with the image's admin password).
- Both repos are committed with a clean working tree; nothing pushed. `sls-test` is ahead of origin.

Findings:

- **Guest bugchecks (stop 0x4A, IRQL_GT_ZERO_AT_SYSTEM_SERVICE) on nested KVM.** On the WSL2 engine (AMD Ryzen AI
  7 PRO 350 host), dockur adds `hv_passthrough` to `-cpu`. With it, Windows crashed three times during the seal
  (phase 1 reboot, DISM, Service Manager stop). With QEMU's default `-action panic=shutdown` plus `hv-crash`, QEMU
  then exits 0: the container logs "Shutdown completed!", with no dump and event 41 BugcheckCode 0. That looks like
  a power off and broke the seal's waits.
  - With `HV=N` the seal passed.
  - A/B at run time (8 GB, 4 cores, both with `panic=pause`): with default `HV` the guest panicked about 500 s
    after start (`VM status: paused (guest-panicked)`); with `HV=N` it stayed healthy past 580 s.
  - A plain `docker run` of the image exited 0 the same way after about 2 min.
  - The screendump at a `panic=pause` stop shows the last frame before the blue screen, so `guest-panicked` is the
    signal, not the picture.
  - The crash dump (`MEMORY.DMP`) could not be analyzed (no debugger on the host).
- **Unclean MongoDB stop with modules (reproduced twice).** Stopping the Service Manager closes about 270 mongod
  connections. NI's `mongodb.conf` has `traceAllExceptions: true`, so each disconnect logs a backtrace, and the
  NoSqlDatabase wrapper kills mongod about 8–12 s into the stop. The log ends mid-backtrace and `mongod.lock` keeps
  the PID. Seal phase 2 now runs `mongod --repair` (2.1 s, exit 0, empty lock).
- **`/oem` bind mount broke resumes.** Install deleted the bind source, and Docker Desktop's WSL bind paths exist
  only for the creating session, so a stopped build container could not start again. Install now uses `docker cp`.
- Seal on this host: phase 1 about 39 s, reboot to ready 85–95 s, Service Manager stop about 31 s, retrim about
  3 min (107 GB trimmed). The pre-seal API probe needs running services: after a failed phase 2, `docker stop` the
  build container and resume `-From Seal` (it starts the VM again).
- Test Monitor needs about 30 s after "healthy" (8 GB guest). Other module routes answer at healthy.

Resume (W4.1a → W4.7):

1. W4.1a/b in `C:\dev\azdo\mraj-sls-container` (see the W4.1 sub-items), then commit locally.
2. Sync and resume in WSL:
   ```bash
   cd ~/sls && git fetch -q /mnt/c/dev/azdo/mraj-sls-container HEAD && git merge --ff-only FETCH_HEAD
   pwsh -NoProfile -File build/Build-SlsImage.ps1 -BuildId wsl-mod1 -From Image
   ```
   (From Windows: `%TEMP%\w4-resume.sh` runs that resume line: `$wp = (wsl -d Ubuntu -- wslpath -a "$env:TEMP/w4-resume.sh").Trim(); wsl -d Ubuntu -- bash $wp`.)
3. W4.3–W4.6 against `sls-server-mod:26.5`. The admin password is in `~/sls/out/builds/wsl-mod1/credentials.json`;
   pass it as `SLS_BUILD_ADMIN_PASSWORD` (from Windows via `WSLENV`).
4. Update §7 (end-to-end time, image size, RAM), mark W4, and commit both repos locally.
5. Clean up: `pwsh build/Build-SlsImage.ps1 -BuildId wsl-mod1 -Cleanup` in `~/sls` (container, volumes, disk
   layer tag); `%TEMP%\w4-*.sh`, `%TEMP%\w4seal`, `%TEMP%\w4diag`. Keep `sls-server-mod:26.5` for W5.
