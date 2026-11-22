#Requires -Version 7.2
<#
.SYNOPSIS
Markdown summary of stability soak results: every run directory below -Path (one per runner in CI), with its soak
jobs (jobs.jsonl and host.json from sls/build/Test-SlsStability.ps1), its image build attempts (build-attempts.json
from scripts/Invoke-SlsBuild.ps1) and runner facts (runner.json), grouped by host CPU.

.EXAMPLE
pwsh scripts/Get-SoakSummary.ps1 -Path soak-artifacts >> $env:GITHUB_STEP_SUMMARY
#>
param(
    [Parameter(Mandatory)][string]$Path,
    # Also write all soak job records, with the run directory and host facts added, to this file (one JSON per line).
    [string]$JsonOut
)
$ErrorActionPreference = 'Stop'
$base = (Resolve-Path $Path).Path
function Read-Json([string]$File) { if (Test-Path $File) { Get-Content $File -Raw | ConvertFrom-Json } }

$dirs = @(Get-ChildItem -LiteralPath $base -Recurse -File -Include jobs.jsonl, host.json, runner.json, build-attempts.json |
    ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
$runs = @(foreach ($d in $dirs) {
        $h = Read-Json (Join-Path $d 'host.json')
        $r = Read-Json (Join-Path $d 'runner.json')
        $jobsFile = Join-Path $d 'jobs.jsonl'
        $jobs = @(if (Test-Path $jobsFile) { Get-Content $jobsFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json } })
        $cpu = if ($r -and $r.cpu) { $r.cpu } elseif ($h) { $h.cpu } else { '?' }
        $kvm = if ($h -and $h.kvm) { $h.kvm } elseif ($r) { (@($r.kvm -split ' ' | Where-Object { $_ -match '^(avic|npt|ept|nested|vls|vgif|vnmi|nrips|lbrv|enable_apicv|enable_shadow_vmcs)=' }) -join ' ') } else { '' }
        [pscustomobject]@{
            Name = if ($d -eq $base) { Split-Path $d -Leaf } else { [IO.Path]::GetRelativePath($base, $d) }
            Cpu = $cpu; Hypervisor = if ($r) { $r.hypervisor } else { '' }; Kvm = $kvm
            Jobs = $jobs; Builds = @(Read-Json (Join-Path $d 'build-attempts.json'))
        }
    })

function Format-Outcomes($jobs) { if (-not $jobs) { return '-' } (($jobs | Group-Object outcome | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ') }
function Get-FailMin($j) { if ($j.failSec) { [math]::Round($j.failSec / 60, 1) } else { '?' } }
function Format-Builds($b) {
    if (-not $b) { return '-' }
    $failed = @($b | Where-Object { $_.result -ne 'ok' })
    $ok = @($b | Where-Object { $_.result -eq 'ok' })
    "$(if ($ok) { 'ok' } else { 'FAILED' }) after $($b.Count) attempt(s), $([math]::Round(($b | Measure-Object minutes -Sum).Sum)) min" +
    $(if ($failed) { '; ' + (($failed | ForEach-Object { "$($_.stage)$(if ($_.bugcheck) { ' bugcheck' })" }) -join ', ') })
}

$all = @($runs | ForEach-Object { $_.Jobs })
$failedJobs = @($all | Where-Object { $_.outcome -ne 'ok' })
$builds = @($runs | ForEach-Object { $_.Builds })
$vmMin = [math]::Round(($all | ForEach-Object { if ($_.failSec) { $_.failSec } else { $_.runSec } } | Measure-Object -Sum).Sum / 60)
$md = [Text.StringBuilder]::new()
[void]$md.AppendLine('## Stability soak')
[void]$md.AppendLine()
[void]$md.AppendLine("**Soak: $($all.Count) jobs in $($runs.Count) run(s), $($failedJobs.Count) failed** ($(Format-Outcomes $all)); $vmMin VM-minutes after start.")
if ($builds) {
    $bFail = @($builds | Where-Object { $_.result -ne 'ok' })
    $buildRuns = @($runs | Where-Object { $_.Builds })
    $okRuns = @($buildRuns | Where-Object { $_.Builds | Where-Object { $_.result -eq 'ok' } })
    [void]$md.AppendLine()
    [void]$md.AppendLine("**Builds: $($okRuns.Count) of $($buildRuns.Count) succeeded, $($builds.Count) attempt(s), $($bFail.Count) failed** ($(@($bFail | Where-Object { $_.bugcheck }).Count) with a Windows bugcheck); $([math]::Round(($builds | Measure-Object minutes -Sum).Sum)) build-minutes.")
}
[void]$md.AppendLine()
[void]$md.AppendLine('### By host CPU')
[void]$md.AppendLine()
[void]$md.AppendLine('| CPU | runs | soak jobs | failed | outcomes | build attempts | failed builds |')
[void]$md.AppendLine('|-----|------|-----------|--------|----------|----------------|---------------|')
foreach ($g in $runs | Group-Object Cpu) {
    $jobs = @($g.Group | ForEach-Object { $_.Jobs })
    $b = @($g.Group | ForEach-Object { $_.Builds })
    [void]$md.AppendLine("| $($g.Name) | $($g.Count) | $($jobs.Count) | $(@($jobs | Where-Object { $_.outcome -ne 'ok' }).Count) | $(Format-Outcomes $jobs) | $($b.Count) | $(@($b | Where-Object { $_.result -ne 'ok' }).Count) |")
}
[void]$md.AppendLine()
[void]$md.AppendLine('### By run')
[void]$md.AppendLine()
[void]$md.AppendLine('| run | CPU | kvm | build | jobs | outcomes | healthy s (median) | failures (min after start: detail) |')
[void]$md.AppendLine('|-----|-----|-----|-------|------|----------|--------------------|------------------------------------|')
foreach ($r in $runs) {
    $healthy = @($r.Jobs | Where-Object { $_.healthySec } | ForEach-Object { [int]$_.healthySec } | Sort-Object)
    $median = if ($healthy) { $healthy[[int][math]::Floor(($healthy.Count - 1) / 2)] } else { '-' }
    $fails = @($r.Jobs | Where-Object { $_.outcome -ne 'ok' } | ForEach-Object { "$($_.lane)-$($_.job) $($_.outcome) @$(Get-FailMin $_): $($_.detail)" })
    $fails += @($r.Builds | Where-Object { $_.result -ne 'ok' } | ForEach-Object { "build $($_.buildId) $($_.stage): $($_.message)" })
    $cpu = "$($r.Cpu)$(if ($r.Hypervisor) { " ($($r.Hypervisor))" })"
    [void]$md.AppendLine("| $($r.Name) | $cpu | $($r.Kvm) | $(Format-Builds $r.Builds) | $($r.Jobs.Count) | $(Format-Outcomes $r.Jobs) | $median | $(($fails -join '<br>') -replace '\|', '/') |")
}
$md.ToString()

if ($JsonOut) {
    $lines = foreach ($r in $runs) {
        foreach ($j in $r.Jobs) {
            $o = [ordered]@{ run = $r.Name; hostCpu = $r.Cpu; hostKvm = $r.Kvm }
            foreach ($p in $j.PSObject.Properties) { $o[$p.Name] = $p.Value }
            [pscustomobject]$o | ConvertTo-Json -Compress -Depth 5
        }
    }
    Set-Content -Path $JsonOut -Value @($lines) -Encoding utf8
}
