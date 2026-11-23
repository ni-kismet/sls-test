# sls-test

Test bed for running NI SystemLink Server in containers on GitHub Actions:

- **build-images** (manual) builds a SystemLink Server base image and seeded configuration images, and publishes them
  to private `ghcr.io/rajsite/sls-server`.
- **e2e-demo** / **e2e-migration** pull one image each, start it and run a Playwright suite against it.

Status and design: [docs/workflow-test-plan.md](docs/workflow-test-plan.md). The image tooling in [sls/](sls) is synced
from its source repository ([sls/SOURCE.md](sls/SOURCE.md)) with `scripts/Sync-SlsTooling.ps1`.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `probe` | manual | Prints runner resources (CPU, RAM, disk, KVM, Docker) after host preparation. |
| `actions-test` | manual | Exercises the actions below: build (base, optionally seeded and pushed), start, check; with `push`, starts the pushed image on a second runner. |
| `soak` | manual | Stability soak: many fresh containers per runner, report per host CPU. |
| `soak-image` | manual | Builds the base image on a hosted runner and records build attempts and VM bugchecks; optional push. |
| `package-delete` | manual | Deletes a test package version. |

## Actions

Composite actions for GitHub-hosted `ubuntu-latest` runners (nested KVM; 4 vCPU, 16 GB). They find their scripts
relative to themselves, so they also work from another repository without checking out this one.

### `sls-start-server`: start SystemLink Server for a test job

```yaml
permissions:
  packages: read
steps:
  - uses: actions/checkout@v4
  - uses: rajsite/sls-test/.github/actions/sls-start-server@<tag or sha>
    with:
      image: ghcr.io/rajsite/sls-server:26.5-migration
      admin-password: ${{ secrets.SLS_ADMIN_PASSWORD }}
  # SLS_BASE_URL (http://127.0.0.1:8080) and SLS_CONTAINER (sls) are now set; the admin user is "admin".
  - run: npx playwright test
    env:
      SLS_PASSWORD: ${{ secrets.SLS_ADMIN_PASSWORD }}
  - if: failure()
    uses: rajsite/sls-test/.github/actions/sls-collect-logs@<tag or sha>
    with:
      artifact: sls-server-logs
      container: sls
      path: ${{ runner.temp }}/sls-start-logs
      admin-password: ${{ secrets.SLS_ADMIN_PASSWORD }}
```

It pulls the image, starts it (the admin password is set at start, any value works), waits for the healthcheck and,
with `wait-for: services` (default), for one read-only call per migration resource (workspaces, users, files, Test
Monitor, feeds, assets, states, systems). A Windows bugcheck or an exited container while starting is retried once
with a new container (`crash-retries`). Typical time from `docker run` to ready on a hosted runner: 3–5 minutes plus
the pull. Inputs: `pull`, `name`, `port`, `ram`, `cpu`, `wait-for` (`services`/`healthy`/`none`), timeouts,
`crash-retries`, `replace`, `license-b64` + `license-user` (user-based license file), `host-prep`. Outputs:
`base-url`, `container`, `pull-sec`, `healthy-sec`, `ready-sec`, `attempts`, `crash`, `host-cpu`.

### `sls-build-image`: build (and push) an image

```yaml
permissions:
  packages: write
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 340
    steps:
      - uses: actions/checkout@v4
      - uses: rajsite/sls-test/.github/actions/sls-build-image@<tag or sha>
        with:
          admin-password: ${{ secrets.SLS_ADMIN_PASSWORD }}
          config: migration          # '' = base image only; demo / migration = seeded image on the base
          repository: ghcr.io/${{ github.repository_owner }}/sls-server
          push: 'true'
```

Builds the base image (Windows + NI Package Manager + SystemLink Server and modules, about 70–90 minutes) with up to
`max-attempts` attempts (a build VM bugcheck restarts with a fresh install, `on-bugcheck`), then optionally a seeded
configuration image (`<base tag>-<config>`), then pushes. `base-image` seeds an existing image instead of building a
base. `reject-cpus` fails fast on host CPU models known to crash builds. Writes a job summary and uploads leak-checked
logs (`upload-logs`).

**Push guard:** the push fails when the package does not exist yet unless `allow-new-package: 'true'`. A first push
with the `GITHUB_TOKEN` of a public repository creates a **public** package, and the image contains the admin
password. Create the package as private first (push once from a private repository or with a PAT, then set its
visibility), or accept a public test package. After every push the summary says whether the package is public.

### `sls-collect-logs`: upload logs safely

Stages files/folders (`path`, one per line) and optionally a container's docker and guest logs (`container`), drops
credentials, OEM files, disks and license files, and runs the leak guard (`scripts/Test-NoSecret.ps1`, which also
looks inside zip and tgz files). Uploads only when no secret was found; otherwise it deletes the staged files and
fails.

### Using the actions from another repository

- Pin `@<tag or sha>`; the actions and their scripts come from that ref.
- Private images: grant the other repository read access to the package (package settings → Manage Actions access),
  then the default `registry-token` (`github.token`) can pull it.
- Secrets: pass the admin password from a secret of the calling repository; the actions mask it and never write it to
  outputs or `GITHUB_ENV`.