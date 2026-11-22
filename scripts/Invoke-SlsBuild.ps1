#Requires -Version 7.2
<#
.SYNOPSIS
Runs sls/build/Build-SlsImage.ps1 and retries a failed build (for example a Windows bugcheck in the build VM on a
nested-KVM runner).

.DESCRIPTION
After a failure the failed stage and message are read from the build's build.log. A failed Install starts over with
a new build id (<BuildId>-a<n>, after cleaning up the failed one); a later stage stops the build container and resumes
the same build with -From <stage>. Every attempt is recorded in sls/out/builds/attempts-<BuildId>.json. GitHub step
outputs (in addition to those of Build-SlsImage.ps1): attempts, bugchecks, final_build_id.

Arguments other than -BuildId and -MaxAttempts are passed to Build-SlsImage.ps1 on the first attempt (a resume
takes them from the build's context.json).

.EXAMPLE
pwsh scripts/Invoke-SlsBuild.ps1 -BuildId gh-123 -MaxAttempts 3 -Repository ghcr.io/rajsite/sls-server-soak -Ram 10G -Cpu 4
#>
param(
    [Parameter(Mandatory)][string]$BuildId,
    [int]$MaxAttempts = 3,
    [Parameter(ValueFromRemainingArguments)][object[]]$BuildArgs = @()
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root 'sls/build/Build-SlsImage.ps1'
$builds = Join-Path $root 'sls/out/builds'
$record = Join-Path $builds "attempts-$BuildId.json"
New-Item -ItemType Directory -Force -Path $builds | Out-Null

function Write-CiOutput([Collections.IDictionary]$Values) {
    if (-not $env:GITHUB_OUTPUT) { return }
    foreach ($k in $Values.Keys) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$k=$($Values[$k])" -Encoding utf8 }
}

function Get-Failure([string]$Id) {
    # Last "stage <name> FAILED: <message>" line of the build's log.
    $log = Join-Path $builds "$Id/build.log"
    $line = if (Test-Path $log) { Select-String -Path $log -Pattern '\] stage (\w+) FAILED: (.*)$' | Select-Object -Last 1 }
    if (-not $line) { return [pscustomobject]@{ stage = 'Install'; message = 'no stage failure in build.log (preflight or setup error)' } }
    return [pscustomobject]@{ stage = $line.Matches[0].Groups[1].Value; message = $line.Matches[0].Groups[2].Value }
}

$attempts = [Collections.Generic.List[object]]::new()
$id = $BuildId; $from = 'Install'; $ok = $false
for ($n = 1; $n -le $MaxAttempts; $n++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "::group::attempt $n of ${MaxAttempts}: build $id from $from"
    if ($from -eq 'Install') { & pwsh -NoProfile -File $build -BuildId $id @BuildArgs }
    else { & pwsh -NoProfile -File $build -BuildId $id -From $from }
    $code = $LASTEXITCODE
    Write-Host '::endgroup::'
    $a = [ordered]@{ attempt = $n; buildId = $id; from = $from; minutes = [math]::Round($sw.Elapsed.TotalMinutes, 1); exit = $code }
    if ($code -eq 0) { $a.result = 'ok'; $attempts.Add($a); $ok = $true; break }

    $f = Get-Failure $id
    $a.result = 'failed'; $a.stage = $f.stage; $a.message = $f.message; $a.bugcheck = [bool]($f.message -match 'bugcheck')
    $attempts.Add($a)
    Write-Host "::warning::build $id failed in $($f.stage)$(if ($a.bugcheck) { ' (Windows bugcheck)' }): $($f.message)"
    $attempts | ConvertTo-Json -Depth 4 | Set-Content $record -Encoding utf8
    if ($n -eq $MaxAttempts) { break }

    $ctxFile = Join-Path $builds "$id/context.json"
    if ($f.stage -eq 'Install' -or -not (Test-Path $ctxFile)) {
        if (Test-Path $ctxFile) { & pwsh -NoProfile -File $build -BuildId $id -Cleanup }
        $id = "$BuildId-a$($n + 1)"; $from = 'Install'
    } else {
        $container = (Get-Content $ctxFile -Raw | ConvertFrom-Json).Container
        if ("$(& docker inspect -f '{{.State.Running}}' $container 2>$null)" -eq 'true') {
            Write-Host "stopping $container before resuming"
            & docker stop -t 60 $container | Out-Null
        }
        $from = $f.stage
    }
}

$attempts | ConvertTo-Json -Depth 4 | Set-Content $record -Encoding utf8
$failures = @($attempts | Where-Object { $_.result -ne 'ok' })
Write-CiOutput ([ordered]@{
        attempts = $attempts.Count; bugchecks = @($failures | Where-Object { $_.bugcheck }).Count; final_build_id = $id
    })
Write-Host "build $(if ($ok) { 'succeeded' } else { 'FAILED' }) after $($attempts.Count) attempt(s), $($failures.Count) failure(s); record $record"
if (-not $ok) { exit 1 }
