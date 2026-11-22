#Requires -Version 7.2
<#
.SYNOPSIS
Leak guard for artifacts of this public repository: fails when a secret appears in any file below -Path.

.DESCRIPTION
Searches every file below -Path, including the entries of .zip files (Playwright traces) and .tgz/.tar.gz files (guest
log bundles), for each secret as plain
text. Default secrets: $env:SLS_ADMIN_PASSWORD, $env:SLS_BUILD_ADMIN_PASSWORD, the passwords in
sls/out/builds/*/credentials.json and the decoded $env:SLS_LICENSE_FILE_B64. On a hit it prints only the file name
(never the match), deletes -Path and exits 1, so nothing gets uploaded.

.EXAMPLE
pwsh scripts/Test-NoSecret.ps1 -Path $env:RUNNER_TEMP/upload
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$Secret = @()
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Split-Path $PSScriptRoot -Parent

$secrets = [Collections.Generic.List[string]]::new()
foreach ($s in @($Secret) + @($env:SLS_ADMIN_PASSWORD, $env:SLS_BUILD_ADMIN_PASSWORD)) { if ($s) { $secrets.Add($s) } }
foreach ($f in Get-ChildItem (Join-Path $root 'sls/out/builds/*/credentials.json') -ErrorAction SilentlyContinue) {
    $c = Get-Content $f -Raw | ConvertFrom-Json
    foreach ($p in 'adminPassword', 'vmPassword') { if ($c.$p) { $secrets.Add([string]$c.$p) } }
}
if ($env:SLS_LICENSE_FILE_B64) {
    $lic = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:SLS_LICENSE_FILE_B64)).Trim()
    # Whole file and its longer lines: a log could hold a fragment.
    $secrets.Add($lic); foreach ($l in $lic -split "`n") { if ($l.Trim().Length -ge 16) { $secrets.Add($l.Trim()) } }
}
$secrets = @($secrets | Where-Object { $_.Length -ge 6 } | Sort-Object -Unique)
if (-not (Test-Path $Path)) { Write-Host "nothing to check: $Path does not exist"; exit 0 }
if (-not $secrets) { Write-Host "::warning::no secrets known to check $Path against"; exit 0 }

function Test-Text([string]$Text) { foreach ($s in $secrets) { if ($Text.Contains($s, [StringComparison]::Ordinal)) { return $true } } $false }
function Read-Bytes([byte[]]$Bytes) {
    # As UTF-8 and UTF-16LE (PowerShell 5 and Windows tools write UTF-16 logs).
    [Text.Encoding]::UTF8.GetString($Bytes) + "`n" + [Text.Encoding]::Unicode.GetString($Bytes)
}

$hits = [Collections.Generic.List[string]]::new()
$files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force)
foreach ($f in $files) {
    if (Test-Text (Read-Bytes ([IO.File]::ReadAllBytes($f.FullName)))) { $hits.Add($f.FullName); continue }
    if ($f.Extension -eq '.zip') {
        $zip = [IO.Compression.ZipFile]::OpenRead($f.FullName)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.Length -eq 0) { continue }
                $ms = [IO.MemoryStream]::new(); $st = $e.Open()
                try { $st.CopyTo($ms) } finally { $st.Dispose() }
                if (Test-Text (Read-Bytes $ms.ToArray())) { $hits.Add("$($f.FullName)!$($e.FullName)") }
            }
        } finally { $zip.Dispose() }
    } elseif ($f.Name -match '\.(tgz|tar\.gz)$') {
        # Guest log bundles (sls-logs). A bundle that can't be read counts as a hit: it can't be checked.
        try {
            $fs = [IO.File]::OpenRead($f.FullName)
            try {
                $tar = [Formats.Tar.TarReader]::new([IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionMode]::Decompress))
                while ($null -ne ($e = $tar.GetNextEntry())) {
                    if (-not $e.DataStream) { continue }
                    $ms = [IO.MemoryStream]::new(); $e.DataStream.CopyTo($ms)
                    if (Test-Text (Read-Bytes $ms.ToArray())) { $hits.Add("$($f.FullName)!$($e.Name)") }
                }
            } finally { $fs.Dispose() }
        } catch { $hits.Add("$($f.FullName) (unreadable: $($_.Exception.Message))") }
    }
}

if ($hits.Count) {
    foreach ($h in $hits) { Write-Host "::error::secret found in $h" }
    Remove-Item -LiteralPath $Path -Recurse -Force
    Write-Host "deleted $Path; nothing from it may be uploaded"
    exit 1
}
Write-Host "no secrets in $($files.Count) file(s) below $Path ($($secrets.Count) secret(s) checked)"
