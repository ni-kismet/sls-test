#Requires -Version 7.2
<#
.SYNOPSIS
Checks of the test workflow after sls-build-image / sls-start-server: outputs and exported variables present, API
reachable at SLS_BASE_URL with the admin password, and (with SEED) the seeded data present (the seed's -Verify).

.DESCRIPTION
Environment: SLS_BASE_URL, SLS_CONTAINER (exported by sls-start-server), START_OUT and optionally BUILD_OUT (toJSON of
the steps' outputs), SEED (seed script path relative to the repository), SLS_ADMIN_PASSWORD (default 'test').
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/testkit/SlsTestKit.psm1') -Force
$fail = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok, [string]$What) { if ($Ok) { Write-Host "ok   $What" } else { Write-Host "FAIL $What"; $fail.Add($What) } }

$start = $env:START_OUT | ConvertFrom-Json -AsHashtable
$build = if ($env:BUILD_OUT) { $env:BUILD_OUT | ConvertFrom-Json -AsHashtable } else { $null }
foreach ($k in 'base-url', 'container', 'healthy-sec', 'ready-sec', 'attempts', 'host-cpu') { Check ([bool]$start[$k]) "sls-start-server output $k = '$($start[$k])'" }
Check ($start['cpu-stability'] -in 'crashy', 'reliable', 'unknown') "sls-start-server output cpu-stability = '$($start['cpu-stability'])'"
Check ($start.ContainsKey('failure') -and -not $start['failure']) "sls-start-server output failure empty ('$($start['failure'])')"
if ($build) {
    foreach ($k in 'image', 'tags', 'base-image', 'config-name', 'minutes', 'versions', 'host-cpu') { Check ([bool]$build[$k]) "sls-build-image output $k = '$($build[$k])'" }
    Check ($build['cpu-stability'] -in 'crashy', 'reliable', 'unknown') "sls-build-image output cpu-stability = '$($build['cpu-stability'])'"
    Check ($build['image'] -match ':\d+\.\d+\.\d+-\d{8}-\d{4}-[a-z0-9_-]+$') "seeded image has a unique dated tag ($($build['image']))"
    Check ($build['digest'] -match '@sha256:[0-9a-f]{64}$') "pushed digest ($($build['digest']))"
}
Check ($env:SLS_BASE_URL -eq $start['base-url']) "SLS_BASE_URL exported ($env:SLS_BASE_URL)"
Check ($env:SLS_CONTAINER -eq 'sls') "SLS_CONTAINER exported ($env:SLS_CONTAINER)"
Check ($env:SLS_BASE_URL -eq 'http://127.0.0.1:8080') 'default port 8080'

$password = if ($env:SLS_ADMIN_PASSWORD) { $env:SLS_ADMIN_PASSWORD } else { 'test' }
$cred = [pscredential]::new('admin', (ConvertTo-SecureString $password -AsPlainText -Force))
$s = Get-SlsServer -Name $env:SLS_CONTAINER -Credential $cred
$rows = Test-SlsServiceCoverage $s
Check (-not @($rows | Where-Object Result -ne 'ok')) "service coverage: $(($rows | ForEach-Object { "$($_.Resource) $($_.Result)" }) -join ', ')"

if ($env:SEED) {
    $env:SLS_TESTKIT = Join-Path $root 'src/testkit/SlsTestKit.psm1'
    $ok = $true
    try { & (Join-Path $root $env:SEED) -BaseUrl $s.BaseUrl -Credential $cred -Container $s.Name -Verify } catch { $ok = $false; Write-Host $_.Exception.Message }
    Check $ok "seeded data present ($env:SEED -Verify)"
}

$md = @('### Action checks', '', "Server $($start['base-url']) healthy $($start['healthy-sec']) s, ready $($start['ready-sec']) s, attempts $($start['attempts']), host $($start['host-cpu']) ($($start['cpu-stability']))")
if ($build) { $md += "Image ``$($build['image'])`` ($($build['minutes']) min, base attempts $($build['attempts']), seed attempts $($build['config-attempts']), digest $($build['digest']))" }
$md += $(if ($fail.Count) { "**FAILED:** $($fail -join '; ')" } else { 'All checks passed.' })
$md -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY
if ($fail.Count) { throw "$($fail.Count) check(s) failed" }
