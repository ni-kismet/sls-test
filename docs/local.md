# Local use

## Requirements

- Linux with KVM (`/dev/kvm`), or Windows with WSL2 and nested virtualization: Docker Engine inside the WSL distro,
  `/dev/kvm` visible there. Guest bugchecks are more frequent on WSL2 than on hosted runners; the test kit and the
  build scripts retry ([history](history/workflow-test-plan.md)).
- PowerShell 7.2+ for the scripts. 16 GB RAM free for a build VM, 8 GB for a server; 60 GB free disk for a build.
- Images: pull a published one (`docker login ghcr.io` for a private package) or build one (below).

## Run a server with docker compose

```powershell
$env:SLS_IMAGE = 'ghcr.io/ni-kismet/sls-server:26.5-demo'
$env:SLS_HTTP_PORT = '8080'                        # default: any free port
docker compose -f src/testkit/compose.yaml up -d --wait
start http://127.0.0.1:8080                        # admin / test
docker compose -f src/testkit/compose.yaml down -t 150      # -v also drops the persistent disk
```

The compose file keeps the guest disk in the volume `sls_sls-storage`, so data survives restarts. Use
`SLS_ADMIN_PASSWORD` for another web admin password (set at start), `SLS_LICENSE_DIR` for a folder with a user-based
license file and `SLS_LICENSE_USER` for its Windows user. Stop with a grace period (`-t 150`): Windows needs it to
shut down cleanly.

## Test with the PowerShell test kit

[SlsTestKit.psm1](../src/testkit/SlsTestKit.psm1) starts throwaway containers on a free port and returns once
SystemLink answers:

```powershell
Import-Module ./src/testkit/SlsTestKit.psm1
$s = Start-SlsServer -Image ghcr.io/ni-kismet/sls-server:26.5-demo   # admin / test
try {
    Invoke-SlsApi $s 'nitag/v2/tags?take=10'
    Wait-SlsCondition { (Invoke-SlsApi $s 'nitag/v2/tags/demo.line1.sensor001/values/current').value.value -eq '1.25' }
    Invoke-SlsGuest $s 'Get-Service NI* | Format-Table -AutoSize'
} catch { Save-SlsLogs $s -Path ./test-logs; throw }
finally { Stop-SlsServer $s }
```

`Start-SlsServer -AdminCredential $cred` sets another password at start; `-Credential $cred` signs in with an image
that already has it. `Test-SlsServiceCoverage $s` calls one read-only API per migration resource. A full example:
[examples/Test-SlsServer.ps1](../src/testkit/examples/Test-SlsServer.ps1).

## Build images

```powershell
pwsh src/build/Build-SlsImage.ps1                                   # base: sls-server:26.5 (60-90 min)
pwsh src/build/New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name demo -Seed src/seeds/demo/Seed.ps1
pwsh src/build/Test-SlsRuntime.ps1 -Image sls-server:26.5-demo     # runtime contract: password, license, restart
```

The base build runs Install → Seal → Convert → Image → Verify. A failed build keeps its state: resume with
`-BuildId <id> -From <stage>`, or clean up with `-BuildId <id> -Cleanup`. Work files go to `src/out` (git-ignored;
`SLS_OUT` moves them). `SLS_BUILD_ADMIN_PASSWORD` sets another admin password (default `test`). Behind a
TLS-inspecting proxy, set `SLS_BUILD_CA_FILE` to a PEM file with the extra root certificates.

To push: `pwsh src/ci/Push-SlsImage.ps1` (see its help), or tag and `docker push` yourself.

Seeds and capturing a hand-made setup with `-FromVolume`: [seeds.md](seeds.md).
