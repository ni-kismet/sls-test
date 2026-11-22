#Requires -Version 7.2
<#
.SYNOPSIS
Markdown summary of stability soak results (sls/build/Test-SlsStability.ps1): every jobs.jsonl below -Path, grouped
by run directory (one per runner) and by host CPU.

.EXAMPLE
pwsh scripts/Get-SoakSummary.ps1 -Path soak-artifacts >> $env:GITHUB_STEP_SUMMARY
#>
param(
    [Parameter(Mandatory)][string]$Path,
    # Also write all job records, with the run directory and host facts added, to this file (one JSON per line).
    [string]$JsonOut
)
$ErrorActionPreference = 'Stop'
$runs = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter jobs.jsonl | ForEach-Object {
        $dir = $_.Directory
        $hostFile = Join-Path $dir 'host.json'
        $h = if (Test-Path $hostFile) { Get-Content $hostFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ cpu = '?'; kvm = '' } }
        $jobs = @(Get-Content $_.FullName | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
        [pscustomobject]@{ Name = [IO.Path]::GetRelativePath((Resolve-Path $Path).Path, $dir.FullName); Host = $h; Jobs = $jobs }
    } | Sort-Object Name)
$runsWithoutJobs = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter host.json | Where-Object { -not (Test-Path (Join-Path $_.Directory 'jobs.jsonl')) })

function Get-FailMin($j) { if ($j.failSec) { [math]::Round($j.failSec / 60, 1) } else { $null } }
function Format-Outcomes($jobs) { (($jobs | Group-Object outcome | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ') }

$all = @($runs | ForEach-Object { $_.Jobs })
$failed = @($all | Where-Object { $_.outcome -ne 'ok' })
$vmMin = [math]::Round(($all | ForEach-Object { if ($_.failSec) { $_.failSec } else { $_.runSec } } | Measure-Object -Sum).Sum / 60)
$md = [Text.StringBuilder]::new()
[void]$md.AppendLine('## Stability soak')
[void]$md.AppendLine()
[void]$md.AppendLine("**$($all.Count) jobs in $($runs.Count) run(s): $($failed.Count) failed** ($(Format-Outcomes $all)); $vmMin VM-minutes.")
if ($runsWithoutJobs) { [void]$md.AppendLine("`n$($runsWithoutJobs.Count) run(s) recorded no job (see their run.log): $(($runsWithoutJobs | ForEach-Object { $_.Directory.Name }) -join ', ')") }
[void]$md.AppendLine()
[void]$md.AppendLine('### By host CPU')
[void]$md.AppendLine()
[void]$md.AppendLine('| CPU | runners | jobs | failed | outcomes |')
[void]$md.AppendLine('|-----|---------|------|--------|----------|')
foreach ($g in $runs | Group-Object { $_.Host.cpu }) {
    $jobs = @($g.Group | ForEach-Object { $_.Jobs })
    [void]$md.AppendLine("| $($g.Name) | $($g.Count) | $($jobs.Count) | $(@($jobs | Where-Object { $_.outcome -ne 'ok' }).Count) | $(Format-Outcomes $jobs) |")
}
[void]$md.AppendLine()
[void]$md.AppendLine('### By runner')
[void]$md.AppendLine()
[void]$md.AppendLine('| run | CPU | kvm | jobs | outcomes | healthy s (median) | failures (min after start: detail) |')
[void]$md.AppendLine('|-----|-----|-----|------|----------|--------------------|------------------------------------|')
foreach ($r in $runs) {
    $healthy = @($r.Jobs | Where-Object { $_.healthySec } | ForEach-Object { [int]$_.healthySec } | Sort-Object)
    $median = if ($healthy) { $healthy[[int][math]::Floor(($healthy.Count - 1) / 2)] } else { '-' }
    $fails = (@($r.Jobs | Where-Object { $_.outcome -ne 'ok' } | ForEach-Object { "$($_.lane)-$($_.job) $($_.outcome) @$(Get-FailMin $_): $($_.detail)" }) -join '<br>') -replace '\|', '/'
    [void]$md.AppendLine("| $($r.Name) | $($r.Host.cpu) | $($r.Host.kvm) | $($r.Jobs.Count) | $(Format-Outcomes $r.Jobs) | $median | $fails |")
}
$md.ToString()

if ($JsonOut) {
    $lines = foreach ($r in $runs) {
        foreach ($j in $r.Jobs) {
            $o = [ordered]@{ run = $r.Name; hostCpu = $r.Host.cpu; hostKvm = $r.Host.kvm }
            foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = $p.Value }
            [pscustomobject]$o | ConvertTo-Json -Compress -Depth 5
        }
    }
    Set-Content -Path $JsonOut -Value $lines -Encoding utf8
}
