# Stage Verify: the built image starts (ephemeral overlay), turns healthy, the API round trip works with the build's
# admin credential, and the guest agent / start hook log lines reach `docker logs`.
param([Parameter(Mandatory)]$Ctx)
$ErrorActionPreference = 'Stop'
$image = $Ctx.Results.Image
if (-not $image -or -not (Test-SlsImage $image)) { throw "image '$image' not found; rerun from Image" }
$creds = Get-Content (Join-Path $Ctx.OutDir 'credentials.json') -Raw | ConvertFrom-Json
$cred = New-SlsCredential $creds.adminUser $creds.adminPassword
$name = "sls-build-$($Ctx.BuildId)-verify"
Remove-SlsContainer $name

$sw = [Diagnostics.Stopwatch]::StartNew()
$server = $null
$lic = if ($Ctx.PSObject.Properties['LicenseFiles']) { @($Ctx.LicenseFiles) } else { @() }
$licUser = if ($Ctx.PSObject.Properties['LicenseUser']) { $Ctx.LicenseUser } else { '' }
try {
    try { $server = Start-SlsServer -Image $image -Name $name -Credential $cred -LicenseFile $lic -LicenseUser $licUser -TimeoutSec 900 }
    catch { throw "verify container did not become healthy: $($_.Exception.Message)" }
    $healthySec = [math]::Round($sw.Elapsed.TotalSeconds)
    Write-SlsLog "verify: healthy after $healthySec s at $($server.BaseUrl)"
    $err = Test-SlsTagRoundTrip -Server $server -Path 'slsbuild.verify.probe' -Value 7.25
    if ($err) { throw "verify: tag round trip failed: $err" }
    $roundTripSec = [math]::Round($sw.Elapsed.TotalSeconds)
    Write-SlsLog "verify: tag round trip ok ($roundTripSec s after start)"
    $coverage = @(Test-SlsServiceCoverage $server -WaitSec 300)
    foreach ($c in $coverage) { Write-SlsLog ("verify: coverage {0,-22} {1,3} {2,-7} {3,5} s {4}" -f $c.Resource, $c.Status, $c.Result, $c.Seconds, $c.Route) }
    # Strict only with the module products (a server-only build has no Test Monitor, assets, states or systems).
    $modules = 'ni-systemlink-software-config-module', 'ni-systemlink-test-module', 'ni-systemlink-asset-module'
    $failedCov = @($coverage | Where-Object Result -eq 'failed')
    if ($failedCov -and -not @($modules | Where-Object { $_ -notin $Ctx.Packages })) {
        throw "verify: service coverage failed: $(($failedCov | ForEach-Object { "$($_.Resource) $($_.Status)" }) -join ', ')"
    }
    $log = (& docker logs $name 2>&1) -join "`n"
    foreach ($p in '[agent]', '[sls]') { if (-not $log.Contains($p)) { throw "verify: no '$p' lines in docker logs" } }
    $runtime = Get-SlsAgentFile $server 'agent/runtime.json'
    $ready = Get-SlsAgentFile $server 'agent/ready.json'
    $Ctx.Results | Add-Member -NotePropertyName Verify -NotePropertyValue ([pscustomobject]@{
            healthySec = $healthySec; tagRoundTripSec = $roundTripSec
            servicesSinceBootSec = $ready.servicesSinceBootSec; httpSinceBootSec = $ready.httpSinceBootSec
            runtimeStatus = $runtime.status
            coverage = @($coverage | ForEach-Object { [pscustomobject]@{ resource = $_.Resource; status = $_.Status; result = $_.Result; seconds = $_.Seconds } })
        }) -Force
} catch {
    & docker logs -t $name *> (Join-Path $Ctx.OutDir 'container-verify.log')
    try { Save-SlsLogs $name -Path $Ctx.OutDir -TimeoutSec 300 | Out-Null } catch { Write-SlsLog "verify: log collection failed: $($_.Exception.Message)" }
    throw
} finally {
    Remove-SlsContainer $name
}
