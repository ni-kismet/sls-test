#Requires -Version 7.2
<#
.SYNOPSIS
Prints one host CPU record for scraping CI logs: a line "sls-host-cpu-v1 <compact JSON>".

.DESCRIPTION
The prefix is fixed; a breaking change to the fields gets a new prefix (sls-host-cpu-v2). Every record has event,
cpu, stability (crashy, reliable or unknown, from host-cpus.tsv), time (UTC) and the run: repository, workflow,
run_id, run_attempt, job, runner. -Field adds the event's fields as key=value (integers and true/false are typed).

Events:
  facts    host-facts.sh (both actions): hypervisor, vcpu, mem_gb, kvm
  start    sls-start-server, also on failure: outcome, image, attempts, bugchecks, crash, healthy_sec, ready_sec
  build    sls-build-image, also on failure: outcome, attempts, bugchecks, config_attempts, config_bugchecks, minutes
  collect  sls-collect-logs with a container (a crash after start): container, status, health, bugcheck, panic

Find them in a run: gh run view <run-id> -R <owner/repo> --log | grep -o 'sls-host-cpu-v1 {.*}' | cut -d' ' -f2-

.EXAMPLE
pwsh src/ci/Write-SlsHostCpuRecord.ps1 -Event start -Cpu "$env:CPU" -Stability crashy outcome=success attempts=1
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory)][ValidateSet('facts', 'start', 'build', 'collect')][string]$Event,
    # Defaults to the lscpu model name.
    [string]$Cpu,
    # Defaults to the host-cpus.tsv classification of -Cpu.
    [string]$Stability,
    # key=value pairs, after the named parameters.
    [Parameter(ValueFromRemainingArguments)][string[]]$Field = @()
)
$ErrorActionPreference = 'Stop'
if (-not $Cpu) {
    $m = @(lscpu 2>$null) | Select-String '^Model name:\s*(.+)$' | Select-Object -First 1
    $Cpu = if ($m) { $m.Matches[0].Groups[1].Value.Trim() } else { '' }
}
if (-not $Stability) {
    $Stability = 'unknown'
    if ($Cpu) {
        $line = & bash (Join-Path $PSScriptRoot 'host-cpu-stability.sh') $Cpu 2>$null
        if ($LASTEXITCODE -eq 0 -and $line) { $Stability = ("$line" -split "`t")[0] }
    }
}

$record = [ordered]@{
    event = $Event; cpu = $Cpu; stability = $Stability; time = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    repository = "$env:GITHUB_REPOSITORY"; workflow = "$env:GITHUB_WORKFLOW"; run_id = "$env:GITHUB_RUN_ID"
    run_attempt = "$env:GITHUB_RUN_ATTEMPT"; job = "$env:GITHUB_JOB"; runner = "$env:RUNNER_NAME"
}
foreach ($f in $Field) {
    $k, $v = "$f" -split '=', 2
    if (-not $k) { continue }
    $record[$k] = if ($v -match '^-?\d{1,15}$') { [long]$v }
    elseif ($v -match '^-?\d{1,15}\.\d+$') { [double]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) }
    elseif ($v -in 'true', 'false') { $v -eq 'true' }
    else { "$v" }
}
Write-Host "sls-host-cpu-v1 $($record | ConvertTo-Json -Compress -Depth 3)"
