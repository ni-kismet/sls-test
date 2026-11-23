#Requires -Version 7.2
<#
.SYNOPSIS
Fast static checks (seconds): every .ps1/.psm1 parses, and every seed script follows the seed contract. Run by ci.yml
and by the plan job of test.yml before any image build starts.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/build/SlsBuild.psm1') -Force
$bad = 0
$files = Get-ChildItem $root -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '[\\/](\.git|out)[\\/]' }
foreach ($f in $files) {
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors) | Out-Null
    foreach ($e in $errors) {
        $bad++
        Write-Host "::error file=$([IO.Path]::GetRelativePath($root, $f.FullName)),line=$($e.Extent.StartLineNumber)::$($e.Message)"
    }
}
$seeds = @(Get-ChildItem (Join-Path $root 'src/seeds') -Recurse -Filter Seed.ps1) + @(Get-ChildItem (Join-Path $root 'tests/seed') -Filter Seed.ps1)
foreach ($s in $seeds) {
    try { Test-SlsSeedScript $s.FullName | Out-Null } catch { $bad++; Write-Host "::error file=$([IO.Path]::GetRelativePath($root, $s.FullName))::$($_.Exception.Message)" }
}
Write-Host "$($files.Count) PowerShell files parsed, $($seeds.Count) seeds checked, $bad problem(s)"
if ($bad) { exit 1 }
