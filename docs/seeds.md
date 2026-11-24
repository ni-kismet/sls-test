# Seeds: images with your data

A **seeded image** is a base image plus data you created through the SystemLink APIs (workspaces, tags, files, test
results, assets, ...). Tests start from it with the data already in place, instead of creating it in every job.

```
base image (60–90 min, rarely)  ->  seed (10–15 min, whenever the data changes)  ->  start in every test job (4–6 min)
```

## Write a seed

A seed is a PowerShell 7 script with this contract:

```powershell
param(
    [Parameter(Mandatory)][string]$BaseUrl,           # http://127.0.0.1:<port> of the work container
    [Parameter(Mandatory)][pscredential]$Credential,  # admin and the image's admin password
    [Parameter(Mandatory)][string]$Container,         # docker container name
    [switch]$Verify)                                  # check the data instead of creating it
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Get-SlsServer -ErrorAction SilentlyContinue)) { Import-Module $env:SLS_TESTKIT }
$server = Get-SlsServer -Name $Container -Credential $Credential

if ($Verify) {
    $v = Wait-SlsCondition { (Invoke-SlsApi $server 'nitag/v2/tags/my.tag/values/current').value.value } -Message 'my.tag'
    if ($v -ne 'hello') { throw "my.tag is '$v'" }
    return
}
Invoke-SlsApi $server 'nitag/v2/tags/my.tag' -Method PUT -Body @{ type = 'STRING'; path = 'my.tag' } | Out-Null
Invoke-SlsApi $server 'nitag/v2/tags/my.tag/values/current' -Method PUT -Body @{ value = @{ type = 'STRING'; value = 'hello' } } | Out-Null
```

- Without `-Verify`: create the data. Throw on failure; the build starts over from the base in a fresh container,
  up to `max-attempts` (3) times.
- With `-Verify`: throw when the data is missing. The build runs it right after seeding and again against a fresh
  container of the finished image; you can call it from your tests too.
- `SLS_TESTKIT` points at [SlsTestKit.psm1](../src/testkit/SlsTestKit.psm1), already imported when the seed runs:
  - `Invoke-SlsApi $server <path> [-Method] [-Body obj | -Content HttpContent]`: authenticated REST call, JSON in and
    out; throws on non-2xx.
  - `Wait-SlsCondition { ... } -TimeoutSec -Message`: poll until truthy. Services can lag a few seconds behind the
    healthcheck, and new workspaces take a moment to reach every service: poll, don't sleep.
  - `Invoke-SlsGuest $server <script>`: run Windows PowerShell in the guest as SYSTEM (for things without an API).
- Keep it idempotent where you can.

Examples: [tests/seed/Seed.ps1](../tests/seed/Seed.ps1) (tags and a file), [src/seeds/demo](../src/seeds/demo)
(100 tags, a file), [src/seeds/migration](../src/seeds/migration) (workspaces, users, files, test results, assets,
systems, feeds from [manifest.json](../src/seeds/migration/manifest.json)).

## Build it

```yaml
- uses: actions/checkout@v7
- uses: ni-kismet/sls-test/sls-build-image@v1
  with:
    base-image: ghcr.io/<owner>/sls-server:26.5
    seed: test/sls/Seed.ps1       # relative to the workspace
    config-name: mydata           # optional; default: the folder name for Seed.ps1, else the file name
    push: 'true'
```

The action checks the script (exists, parses, has the four parameters) before anything else. Then it:

1. Starts the base in a work container and sets the admin password (`admin-password`, default `test`).
2. Runs the seed, then the seed with `-Verify`, then shuts Windows down cleanly (NI services stopped, MongoDB closed).
3. Commits the guest disk as a layer on the base (`src/image/config.Dockerfile`), which adds only the changed blocks.
4. Starts the new image fresh and runs the seed with `-Verify`.

Tags: `<repo>:<x.y.z>-<yyyyMMdd>-<HHmm>-<config-name>` (never overwritten), `<repo>:<sls-version>-<config-name>`
(moving; `floating-tag: 'false'` to skip), and `<tag>-<config-name>` for each `tags` entry.

A seed can't change what's installed (use `packages` on the base for that), and it should not depend on the
license: modules run on their evaluation period unless you pass `license-b64`.

## Locally

```powershell
pwsh src/build/New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name mydata -Seed path/to/Seed.ps1
```

Or capture a server you set up by hand: start a base with a named volume (`src/testkit/compose.yaml`), click your
data together, stop it, and run `New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name mydata -FromVolume <volume>`.
See [local.md](local.md).
