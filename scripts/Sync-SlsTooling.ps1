#Requires -Version 7.2
<#
.SYNOPSIS
Mirrors the SystemLink image tooling from the mraj-sls-container repository into sls/ of this repository.

.DESCRIPTION
Copies the git-tracked files of build/, image/, testkit/ and configs/ from -Source (a clean checkout) into sls/,
removing files that no longer exist in the source. Untracked and ignored files (out/, credentials, disks) are never
copied. Writes sls/SOURCE.md with the source repository, commit and date. Commit sls/ afterwards.

.EXAMPLE
pwsh scripts/Sync-SlsTooling.ps1 -Source C:\dev\azdo\mraj-sls-container
#>
param(
    [Parameter(Mandatory)][string]$Source,
    [string[]]$Folder = @('build', 'image', 'testkit', 'configs')
)
$ErrorActionPreference = 'Stop'
$Source = (Resolve-Path $Source).Path
$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'sls'

$dirty = & git -C $Source status --porcelain
if ($LASTEXITCODE) { throw "$Source is not a git checkout" }
if ($dirty) { throw "$Source has uncommitted changes; commit or stash them first:`n$($dirty -join "`n")" }

$files = @(& git -C $Source ls-files -- $Folder)
if (-not $files) { throw "no tracked files under $($Folder -join ', ') in $Source" }

foreach ($f in $Folder) {
    $dir = Join-Path $target $f
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}
foreach ($f in $files) {
    $dst = Join-Path $target $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Source $f) -Destination $dst
}

$commit = "$(& git -C $Source rev-parse HEAD)".Trim()
$subject = "$(& git -C $Source log -1 --format=%s)".Trim()
# Name only: the source is an internal repository and this one is public.
$name = Split-Path -Leaf ("$(& git -C $Source remote get-url origin 2>$null)".Trim() -replace '\.git$', '' | ForEach-Object { if ($_) { $_ } else { $Source } })
@"
# Source of sls/

Mirrored by ``scripts/Sync-SlsTooling.ps1``; do not edit here, change the source and sync again.

- Repository: $name
- Commit: ``$commit`` ($subject)
- Folders: $($Folder -join ', ') ($($files.Count) files)
- Synced: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC
"@ | Set-Content -Path (Join-Path $target 'SOURCE.md') -Encoding utf8

Write-Host "synced $($files.Count) files from $Source @ $($commit.Substring(0, 7)) into $target"
