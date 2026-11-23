#Requires -Version 7.2
<#
.SYNOPSIS
Checks of the actions-test workflow after sls-build-image / sls-start-server: outputs and exported variables present,
API reachable at SLS_BASE_URL, no secret in any output, and (with CONFIG) the seeded data present (the seed's -Verify).

.DESCRIPTION
Environment: SLS_ADMIN_PASSWORD, SLS_BASE_URL, SLS_CONTAINER (exported by sls-start-server), START_OUT and optionally
BUILD_OUT (toJSON of the steps' outputs), CONFIG.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'sls/testkit/SlsTestKit.psm1') -Force
$fail = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok, [string]$What) { if ($Ok) { Write-Host "ok   $What" } else { Write-Host "FAIL $What"; $fail.Add($What) } }

$start = $env:START_OUT | ConvertFrom-Json -AsHashtable
$build = if ($env:BUILD_OUT) { $env:BUILD_OUT | ConvertFrom-Json -AsHashtable } else { $null }
foreach ($k in 'base-url', 'container', 'healthy-sec', 'ready-sec', 'attempts', 'host-cpu') { Check ([bool]$start[$k]) "sls-start-server output $k = '$($start[$k])'" }
if ($build) { foreach ($k in 'image', 'tags', 'base-image', 'attempts', 'minutes', 'versions', 'host-cpu') { Check ([bool]$build[$k]) "sls-build-image output $k = '$($build[$k])'" } }
Check ($env:SLS_BASE_URL -eq $start['base-url']) "SLS_BASE_URL exported ($env:SLS_BASE_URL)"
Check ($env:SLS_CONTAINER -eq 'sls') "SLS_CONTAINER exported ($env:SLS_CONTAINER)"
Check ($env:SLS_BASE_URL -eq 'http://127.0.0.1:8080') 'default port 8080'
$all = "$env:START_OUT $env:BUILD_OUT"
Check (-not $all.Contains($env:SLS_ADMIN_PASSWORD)) 'no admin password in step outputs'

$cred = [pscredential]::new('admin', (ConvertTo-SecureString $env:SLS_ADMIN_PASSWORD -AsPlainText -Force))
$s = Get-SlsServer -Name $env:SLS_CONTAINER -Credential $cred
$rows = Test-SlsServiceCoverage $s
Check (-not @($rows | Where-Object Result -ne 'ok')) "service coverage: $(($rows | ForEach-Object { "$($_.Resource) $($_.Result)" }) -join ', ')"

if ($env:CONFIG) {
    $seed = Join-Path $root "sls/configs/$env:CONFIG/Seed.ps1"
    $ok = $true
    try { & $seed -BaseUrl $s.BaseUrl -Credential $cred -Container $s.Name -Verify } catch { $ok = $false; Write-Host $_.Exception.Message }
    Check $ok "seeded data of $env:CONFIG present (Seed.ps1 -Verify)"
}

$md = @('### actions-test checks', '', "Server $($start['base-url']) healthy $($start['healthy-sec']) s, ready $($start['ready-sec']) s, attempts $($start['attempts']), host $($start['host-cpu'])")
if ($build) { $md += "Image ``$($build['image'])`` ($($build['minutes']) min, base attempts $($build['attempts']), bugchecks $($build['bugchecks']), digest $($build['digest']))" }
$md += $(if ($fail.Count) { "**FAILED:** $($fail -join '; ')" } else { 'All checks passed.' })
$md -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY
if ($fail.Count) { throw "$($fail.Count) check(s) failed" }
