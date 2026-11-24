# sls-test

GitHub Actions for running **NI SystemLink Server** in a container on GitHub-hosted Ubuntu runners, for integration
tests. SystemLink Server is a Windows application; the image runs a sealed Windows Server VM with SystemLink Server
installed under QEMU/KVM ([dockur/windows](https://github.com/dockur/windows)). Hosted `ubuntu-*` runners have nested
KVM, so no self-hosted runner is needed.

| Action | What it does | Time |
|--------|--------------|------|
| [`sls-start-server`](sls-start-server/action.yml) | Pulls an image, starts it, waits until the APIs answer, exports `SLS_BASE_URL`. | 4–6 min |
| [`sls-build-image`](sls-build-image/action.yml) | Builds a base image (Windows + NI Package Manager + SystemLink Server), and/or a seeded image with your data on top; pushes to ghcr.io. | base 60–90 min, seed 10–15 min |
| [`sls-collect-logs`](sls-collect-logs/action.yml) | Uploads docker and guest logs after a failure, with a leak check. | 1 min |

The web admin user is **`admin` / `test`** unless you choose another password. These are local test servers,
reachable only on `127.0.0.1` of the runner.

## Quick start

### Test against a server

```yaml
jobs:
  test:
    runs-on: ubuntu-26.04
    permissions:
      packages: read
    steps:
      - uses: actions/checkout@v7
      - uses: ni-kismet/sls-test/sls-start-server@v1
        with:
          image: ghcr.io/<owner>/sls-server:26.5-mydata
      # SLS_BASE_URL=http://127.0.0.1:8080 and SLS_CONTAINER=sls are set; sign in as admin / test.
      - run: npm test
      - if: failure()
        uses: ni-kismet/sls-test/sls-collect-logs@v1
        with:
          container: sls
          artifact: sls-logs
```

### Build an image with your data

Build the base once, then seed it as often as you like. A seed is a PowerShell script that creates data through the
SystemLink APIs ([docs/seeds.md](docs/seeds.md)); the seeded image starts with that data already in place.

```yaml
jobs:
  base:                                   # rarely: new SystemLink version
    runs-on: ubuntu-26.04
    timeout-minutes: 340
    permissions:
      packages: write
    steps:
      - uses: ni-kismet/sls-test/sls-build-image@v1
        with:
          push: 'true'                    # ghcr.io/<owner>/sls-server:26.5 and :<x.y.z>-<yyyyMMdd>-<HHmm>

  seed:                                   # whenever the seed changes
    runs-on: ubuntu-26.04
    timeout-minutes: 120
    permissions:
      packages: write
    steps:
      - uses: actions/checkout@v7
      - uses: ni-kismet/sls-test/sls-build-image@v1
        with:
          base-image: ghcr.io/<owner>/sls-server:26.5
          seed: test/sls/Seed.ps1         # your script; or a built-in seed: demo, migration
          push: 'true'                    # ghcr.io/<owner>/sls-server:26.5-sls (the seed's folder name)
```

Use the `digest` output to start exactly the image you built in a later job.

## Actions

Pin a release (`@v1`, or `@v1.0.0` / a commit SHA). The actions run their scripts from that ref; you don't need to
check out this repository.

### `sls-start-server`

| Input | Default | |
|-------|---------|---|
| `image` | (required) | Image to start (tag or `<repo>@sha256:...`). Pulled only when not local. |
| `admin-password` | `test` | Web admin password; set at start when the image has another one (about 40 s). |
| `wait-for` | `services` | `services`: healthy and every SystemLink API used by migrations answers; `healthy`; `none`. |
| `port` | `8080` | Host port on `127.0.0.1` (`0` = any free port). |
| `license-b64`, `license-user` | | Optional user-based license file (base64) and the Windows user it was issued to. |

Advanced: `name` (`sls`), `ram` (`8G`), `cpu` (`4`), `healthy-timeout-minutes`, `services-timeout-minutes`,
`crash-retries` (`1`: a new container after a Windows bugcheck while starting), `replace`, `registry-token`,
`host-prep`, `min-free-gb`.

Outputs: `base-url`, `container`, `pull-sec`, `healthy-sec`, `ready-sec`, `attempts`, `crash`, `host-cpu`. Exports
`SLS_BASE_URL` and `SLS_CONTAINER` to later steps.

### `sls-build-image`

| Input | Default | |
|-------|---------|---|
| `seed` | | Built-in seed (`demo`, `migration`) or the path of a seed script in your workspace. Empty = base only. |
| `config-name` | seed name | Tag suffix of the seeded image (the built-in name, or the seed's folder name for `Seed.ps1`, else its file name). |
| `base-image` | | Existing base to seed instead of building one (tag or digest). |
| `repository` | `ghcr.io/<owner>/sls-server` | Repository of the images. |
| `push` | `false` | Push to ghcr.io (needs `packages: write`). |
| `admin-password` | `test` | Web admin password of the images built here. |
| `sls-version` | `26.5` | SystemLink Server feed version of a base built here. |
| `packages` | | NI packages to install. Empty = SystemLink Server + Test, Asset and Software Configuration modules. |

Advanced: `tags` (extra tags; a seeded image gets `<tag>-<config-name>`), `floating-tag` (`true`: also move
`<sls-version>[-<config-name>]`), `license-b64`, `license-user`, `ram`, `cpu`, `max-attempts` (`3`), `reject-cpus`,
`registry-token`, `host-prep`, `min-free-gb`, `upload-logs` (`always`/`failure`/`never`), `log-artifact`.

Outputs: `image`, `tags`, `digest`, `base-image`, `config-name`, `public`, `build-id`, `attempts`, `bugchecks`,
`config-attempts`, `host-cpu`, `minutes`, `versions`.

The seed is checked first (exists, parses, has the seed parameters), so a wrong path fails in seconds, not after the
base build. A build VM that crashes is rebuilt from the install stage, up to `max-attempts`.

### `sls-collect-logs`

| Input | Default | |
|-------|---------|---|
| `artifact` | (required) | Artifact name. |
| `container` | | Container whose docker log, state and guest logs to include. |
| `path` | | Extra files or folders, one per line. |
| `admin-password` | | A custom admin password to check the logs for. |

Drops credentials, disks and license files, then checks the remaining files (also inside zip/tgz) for secrets. It
uploads only when none is found.

## Images and tags

| Tag | Moves? | |
|-----|--------|---|
| `<repo>:26.5`, `<repo>:26.5.1` | yes | Newest base for the feed / exact version. |
| `<repo>:26.5-<config>` | yes | Newest seeded image. |
| `<repo>:26.5.1-20261120-1015[-<config>]` | no | One build (UTC time), never overwritten. |
| `<repo>:r<run>[-<config>]` | no | Extra tags from `tags`. |

Images carry labels: `org.opencontainers.image.version`, `com.ni.sls.products`, `com.ni.sls.windows-eval-expires`,
`com.ni.sls.admin-password` (`test` or `custom`, never the value).

The `build-images` workflow of this repository publishes `ghcr.io/ni-kismet/sls-server` (`26.5`, `26.5-demo`,
`26.5-migration`). The package is private; build your own with `sls-build-image` or ask for access.

## Limits

- GitHub-hosted Linux runners (nested KVM; 4 vCPU, 16 GB), tested on `ubuntu-26.04`; pin the label so an image
  switch of `ubuntu-latest` can't change kernel, disk layout or pwsh under you. Host preparation frees disk space until
  60 GB (build) or 40 GB (start) are free.
- Windows Server evaluation: about 180 days after the base build (label `com.ni.sls.windows-eval-expires`).
  SystemLink module evaluations end 45 days after the base build; after that their UI pages are disabled unless you
  pass a license file. Rebuild the base regularly.
- The guest occasionally bugchecks on some host CPUs; start and build retry automatically (`crash-retries`,
  `max-attempts`, `reject-cpus`).
- A first push with the `GITHUB_TOKEN` of a public repository creates a public package. The image contains the
  web admin password (`test` unless you set another).

## Run a server locally

Needs Docker with `/dev/kvm`: Linux with KVM, or Docker on Windows with WSL2 and nested virtualization. The test
package `ghcr.io/ni-kismet/sls-server-actions-test` is public, so no `docker login` is needed. Tags:

| Tag | Contents |
|-----|----------|
| `26.5` | Base server, no data. |
| `26.5-demo` | 100 tags (`demo.line<1..10>.sensor<001..100>`) and one file. No test results. |
| `26.5-migration` | Workspaces, users, files, Test Monitor products, results and steps, a feed, assets, states and tags ([manifest](src/seeds/migration/manifest.json)). |

Pull the image (~20 GB):

```bash
docker pull ghcr.io/ni-kismet/sls-server-actions-test:26.5-demo
```

Start it (`SLS_HEALTH_AUTH` makes the healthcheck sign in, so `healthy` means the API is usable):

```bash
docker run -d --name sls --device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN --stop-timeout 150 -p 127.0.0.1:8080:80 -e SLS_HEALTH_AUTH=admin:test ghcr.io/ni-kismet/sls-server-actions-test:26.5-demo
```

The `docker` commands work the same in bash, PowerShell and cmd. Wait until the status goes from `starting` to
`healthy` (~3-4 min), then open http://127.0.0.1:8080 and sign in as admin / test:

```bash
docker inspect -f "{{.State.Health.Status}}" sls
```

`healthy` means every NI service is running, the web server is up, and authenticated calls to the auth and tag
services succeed. The module services (Test Monitor, assets, systems) can answer up to ~30 s later. If you need one
of them, poll its API, for example Test Monitor.

PowerShell (Windows PowerShell 5.1 or 7; `YWRtaW46dGVzdA==` is `admin:test` in base64). `-UserAgent` is required:
the NI web server treats PowerShell's default `Mozilla/5.0 ...` user agent as a browser and answers with the login
page (401/302) instead of checking basic auth.

```powershell
while ($true) { try { Invoke-RestMethod -UserAgent sls-wait -Method Post -Uri http://127.0.0.1:8080/nitestmonitor/v2/query-results -ContentType application/json -Body '{"take":1}' -Headers @{ Authorization = 'Basic YWRtaW46dGVzdA==' } | Out-Null; break } catch { Write-Host $_.Exception.Message; Start-Sleep -Seconds 5 } }
```

bash:

```bash
until curl -sf -u admin:test -H 'Content-Type: application/json' -d '{"take":1}' http://127.0.0.1:8080/nitestmonitor/v2/query-results >/dev/null; do sleep 5; done
```

Stop and remove it (the grace period lets Windows shut down):

```bash
docker stop -t 150 sls
docker rm sls
```

- `-e SLS_ADMIN_PASSWORD=<pw>`: another web admin password, set at start (~40 s more).
- `-e RAM_SIZE=8G -e CPU_CORES=4`: VM size (the defaults).
- `-v sls-storage:/storage`: keep the data across containers; without it every container starts from the image.

With docker compose (keeps the data in a volume; `down -v` also deletes it):

```powershell
$env:SLS_IMAGE = 'ghcr.io/ni-kismet/sls-server-actions-test:26.5-demo'
$env:SLS_HTTP_PORT = '8080'
$env:SLS_HEALTH_AUTH = 'admin:test'
docker compose -f src/testkit/compose.yaml up -d --wait
docker compose -f src/testkit/compose.yaml down -t 150
```

## Local use and development

- Run an image locally with Docker Desktop (WSL2) or Linux with KVM, build images, use the PowerShell test kit:
  [docs/local.md](docs/local.md).
- Layout: actions in the top-level folders; scripts in [src/](src) (`build/`, `image/`, `ci/`, `seeds/`,
  `testkit/`); tests in [tests/](tests).
- Workflows: [`ci`](.github/workflows/ci.yml) (lint, every push), [`test`](.github/workflows/test.yml) (builds with the
  fixture seed [tests/seed/Seed.ps1](tests/seed/Seed.ps1), reusing the test package base unless base content changed,
  then starts the pushed image on a fresh runner), [`build-images`](.github/workflows/build-images.yml) (manual
  publish).
- History: [docs/history/workflow-test-plan.md](docs/history/workflow-test-plan.md),
  [docs/actions-layout-plan.md](docs/actions-layout-plan.md).

## License

[MIT](LICENSE)
