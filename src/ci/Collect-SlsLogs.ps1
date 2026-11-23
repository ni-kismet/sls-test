#Requires -Version 7.2
<#
.SYNOPSIS
Stages logs for upload from a public repository: copies -Path entries without credentials, OEM files, disks or
license files, optionally adds a container's logs (docker logs + guest logs), then runs the leak guard.

.DESCRIPTION
Used by the sls-collect-logs, sls-build-image and sls-start-server actions (composite actions can't nest local
actions, so they share this script). Each -Path (file or folder; missing ones are skipped) is copied below -Out under
its leaf name (with pwsh -File, pass several paths as one newline-separated argument). With -Container, docker logs
and the guest's sls-logs bundle are added under -Out/<container>.
Then Test-NoSecret.ps1 checks -Out: on a hit it deletes -Out and this script exits 1, so the caller's upload
step (if: success) uploads nothing. Secrets checked: those of Test-NoSecret.ps1 plus -Secret.

.EXAMPLE
pwsh src/ci/Collect-SlsLogs.ps1 -Out $env:RUNNER_TEMP/logs -Path $env:RUNNER_TEMP/sls/builds -Container sls
#>
param(
    [Parameter(Mandatory)][string]$Out,
    [string[]]$Path = @(),
    [string]$Container,
    [string[]]$Secret = @()
)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$exclude = @('credentials.json', 'ca-certificates.crt', '*.qcow2', '*.img', '*.iso', '*.lic')
$excludeDir = @('oem', '.auth', 'sls-licenses', 'licenses')

function Copy-Clean([IO.FileSystemInfo]$Item, [string]$Dest) {
    if ($Item -is [IO.DirectoryInfo]) {
        if ($Item.Name -in $excludeDir) { return }
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        foreach ($c in Get-ChildItem -LiteralPath $Item.FullName -Force) { Copy-Clean $c (Join-Path $Dest $c.Name) }
    } else {
        foreach ($p in $exclude) { if ($Item.Name -like $p) { return } }
        Copy-Item -LiteralPath $Item.FullName -Destination $Dest -Force
    }
}

New-Item -ItemType Directory -Force -Path $Out | Out-Null
foreach ($p in $Path | ForEach-Object { $_ -split '[\r\n]+' } | Where-Object { $_ -and $_.Trim() }) {
    $p = $p.Trim()
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "skip $p (not found)"; continue }
    $item = Get-Item -LiteralPath $p -Force
    Copy-Clean $item (Join-Path $Out $item.Name)
}

if ($Container) {
    $exists = "$(& docker inspect -f '{{.Name}}' $Container 2>$null)".Trim()
    if (-not $exists) { Write-Host "skip container $Container (not found)" }
    else {
        $dir = Join-Path $Out $Container
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        & docker inspect -f '{{json .State}}' $Container 2>$null | Set-Content (Join-Path $dir 'state.json')
        Import-Module (Join-Path $src 'testkit/SlsTestKit.psm1') -Force
        # docker log always; the guest log bundle only while the container runs.
        try { Save-SlsLogs $Container -Path $dir -TimeoutSec 300 | Out-Null }
        catch { Write-Host "::warning::log collection from $Container failed: $($_.Exception.Message)" }
    }
}

$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot 'Test-NoSecret.ps1') -Path $Out -Secret $Secret
exit $global:LASTEXITCODE
