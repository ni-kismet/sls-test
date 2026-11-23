#Requires -Version 7.2
<#
.SYNOPSIS
CI build of a SystemLink Server image (body of the sls-build-image action): base image with retries, then optionally a
seeded configuration image with retries, one set of step outputs and a job summary.

.DESCRIPTION
Base image: scripts/Invoke-SlsBuild.ps1 (Build-SlsImage.ps1 with attempts; -OnBugcheck restart|resume), unless
-BaseImage names an existing image (pulled when not present locally).
Configuration image (-Config): sls/build/New-SlsConfigImage.ps1 with the seed sls/configs/<Config>/Seed.ps1 (or
-ConfigSeed), tag <base repository>:<base tag>-<Config>, every -ExtraTag also as <tag>-<Config>. Every attempt starts
fresh (a failed attempt's out folder is kept as sls/out/configs/<Config>-fail<n> for the logs).

The admin password of the base image comes from SLS_BUILD_ADMIN_PASSWORD (both builds read it).

GitHub step outputs: image (the configuration image if any, else the base image), image_id, tags, base_image,
base_tags, config_image, sls_full_version, build_id, attempts, bugchecks, config_attempts, config_bugchecks, minutes,
versions (JSON). Writes sls/out/ci-build.json; the logs are in sls/out/builds and sls/out/configs.

.EXAMPLE
pwsh scripts/ci/Build-SlsCi.ps1 -BuildId gh-123 -Repository ghcr.io/rajsite/sls-server -Ram 10G -Cpu 4 -Config migration
#>
param(
    [Parameter(Mandatory)][string]$BuildId,
    [string]$SlsVersion = '26.5',
    # Comma or newline separated; empty = Build-SlsImage.ps1 defaults.
    [string]$Packages = '',
    [string]$Feeds = '',
    [string]$Repository = 'sls-server',
    [string]$ExtraTag = '',
    [string]$Ram = '10G',
    [int]$Cpu = 4,
    [int]$MaxAttempts = 3,
    [ValidateSet('restart', 'resume')][string]$OnBugcheck = 'restart',
    [string]$BaseImage = '',
    [string]$Config = '',
    [string]$ConfigSeed = '',
    [int]$ConfigAttempts = 3,
    [string]$LicenseUser = $env:SLS_LICENSE_USER,
    [string]$LicenseFile = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sls = Join-Path $root 'sls'
$ciOutput = $env:GITHUB_OUTPUT

function Split-List([string]$Text) { @($Text -split '[,\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Write-CiOutput([Collections.IDictionary]$Values) {
    if (-not $ciOutput) { return }
    foreach ($k in $Values.Keys) { Add-Content -Path $ciOutput -Value "$k=$($Values[$k])" -Encoding utf8 }
}
function Invoke-Child([string]$Script, [object[]]$Arguments) {
    # Runs a build script with its GITHUB_OUTPUT redirected; returns its exit code and outputs.
    $tmp = New-TemporaryFile
    $env:GITHUB_OUTPUT = $tmp.FullName
    try {
        $lines = [Collections.Generic.List[string]]::new()
        & pwsh -NoProfile -File $Script @Arguments 2>&1 | ForEach-Object { $s = "$_"; $lines.Add($s); if ($lines.Count -gt 200) { $lines.RemoveAt(0) }; Write-Host $s }
        $code = $LASTEXITCODE
    } finally { $env:GITHUB_OUTPUT = $ciOutput }
    $o = [ordered]@{}
    foreach ($l in Get-Content $tmp.FullName) { if ($l -match '^([\w-]+)=(.*)$') { $o[$matches[1]] = $matches[2] } }
    Remove-Item $tmp.FullName -Force
    return [pscustomobject]@{ Code = $code; Out = $o; Tail = $lines }
}

$record = [ordered]@{ buildId = $BuildId; base = $null; config = $null }
$total = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{ image = ''; image_id = ''; tags = ''; base_image = ''; base_tags = ''; config_image = ''; sls_full_version = ''
    build_id = ''; attempts = 0; bugchecks = 0; config_attempts = 0; config_bugchecks = 0 }
$failed = $null

# ------------------------------------------------------------ base image
if ($BaseImage) {
    & docker image inspect $BaseImage *> $null
    if ($LASTEXITCODE -ne 0) {
        for ($i = 1; ; $i++) {
            & docker pull $BaseImage
            if ($LASTEXITCODE -eq 0) { break }
            if ($i -ge 3) { throw "docker pull $BaseImage failed 3 times" }
            Start-Sleep -Seconds (30 * $i)
        }
    }
    $result.base_image = $BaseImage; $result.base_tags = $BaseImage
    $result.sls_full_version = "$(& docker image inspect -f '{{index .Config.Labels "com.ni.sls.version"}}' $BaseImage 2>$null)".Trim()
    $record.base = [ordered]@{ image = $BaseImage; built = $false }
} else {
    $a = @('-BuildId', $BuildId, '-MaxAttempts', $MaxAttempts, '-OnBugcheck', $OnBugcheck, '-SlsVersion', $SlsVersion,
        '-Repository', $Repository, '-Ram', $Ram, '-Cpu', $Cpu)
    if ($Packages) { $a += @('-Packages', ((Split-List $Packages) -join ',')) }
    if ($Feeds) { $a += @('-Feeds', ((Split-List $Feeds) -join ',')) }
    if ($ExtraTag) { $a += @('-ExtraTag', ((Split-List $ExtraTag) -join ',')) }
    if ($LicenseFile) { $a += @('-LicenseFile', $LicenseFile) }
    if ($LicenseUser) { $a += @('-LicenseUser', $LicenseUser) }
    $r = Invoke-Child (Join-Path $root 'scripts/Invoke-SlsBuild.ps1') $a
    $result.attempts = [int]$r.Out['attempts']; $result.bugchecks = [int]$r.Out['bugchecks']; $result.build_id = $r.Out['final_build_id']
    $record.base = [ordered]@{ built = $true; exit = $r.Code; outputs = $r.Out }
    if ($r.Code -ne 0) { $failed = "base image build failed after $($result.attempts) attempt(s)" }
    else {
        $result.base_image = $r.Out['image']; $result.base_tags = $r.Out['tags']; $result.sls_full_version = $r.Out['sls_full_version']
        $result.image_id = $r.Out['image_id']
    }
}
$result.image = $result.base_image; $result.tags = $result.base_tags
if (-not $result.image_id -and $result.base_image) { $result.image_id = "$(& docker image inspect -f '{{.Id}}' $result.base_image)".Trim() }

# ------------------------------------------------------------ configuration image
if ($Config -and -not $failed) {
    $seed = if ($ConfigSeed) { $ConfigSeed } else { Join-Path $sls "configs/$Config/Seed.ps1" }
    if (-not (Test-Path $seed)) { throw "seed script $seed not found (-Config $Config)" }
    $baseTag = $result.base_image
    $i = $baseTag.LastIndexOf(':')
    $cfgTag = "$($baseTag.Substring(0, $i)):$($baseTag.Substring($i + 1))-$Config"
    $cfgExtra = @(Split-List $ExtraTag | ForEach-Object { "$_-$Config" })
    $cfgDir = Join-Path $sls "out/configs/$Config"
    $attempts = [Collections.Generic.List[object]]::new()
    for ($n = 1; $n -le $ConfigAttempts; $n++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Write-Host "::group::configuration image $Config attempt $n of $ConfigAttempts"
        $a = @('-BaseImage', $baseTag, '-Name', $Config, '-Seed', $seed, '-Tag', $cfgTag, '-Ram', $Ram, '-Cpu', $Cpu)
        if ($cfgExtra) { $a += @('-ExtraTag', ($cfgExtra -join ',')) }
        if ($LicenseFile) { $a += @('-LicenseFile', $LicenseFile) }
        if ($LicenseUser) { $a += @('-LicenseUser', $LicenseUser) }
        $r = Invoke-Child (Join-Path $sls 'build/New-SlsConfigImage.ps1') $a
        Write-Host '::endgroup::'
        $at = [ordered]@{ attempt = $n; minutes = [math]::Round($sw.Elapsed.TotalMinutes, 1); exit = $r.Code }
        if ($r.Code -eq 0) {
            $at.result = 'ok'; $attempts.Add($at)
            $result.image = $r.Out['image']; $result.image_id = $r.Out['image_id']; $result.tags = $r.Out['tags']; $result.config_image = $r.Out['image']
            break
        }
        $msg = "$($r.Tail | Where-Object { $_ -match 'bugcheck|Exception|failed|error|not healthy|is exited' -and $_ -notmatch '^::' } | Select-Object -Last 1)".Trim()
        if (-not $msg) { $msg = "exit $($r.Code)" }
        $msg = $msg.Substring(0, [Math]::Min(300, $msg.Length))
        $at.result = 'failed'; $at.message = $msg; $at.bugcheck = [bool]($msg -match 'bugcheck')
        $attempts.Add($at)
        Write-Host "::warning::configuration image $Config attempt $n failed$(if ($at.bugcheck) { ' (Windows bugcheck)' }): $msg"
        if (Test-Path $cfgDir) {
            $keep = "$cfgDir-fail$n"
            Remove-Item $keep -Recurse -Force -ErrorAction SilentlyContinue
            Get-ChildItem $cfgDir -Filter '*.qcow2' | Remove-Item -Force
            Move-Item $cfgDir $keep
        }
    }
    $result.config_attempts = $attempts.Count
    $result.config_bugchecks = @($attempts | Where-Object { $_['bugcheck'] }).Count
    $record.config = [ordered]@{ name = $Config; seed = $seed; tag = $cfgTag; attempts = $attempts }
    if (-not $result.config_image) { $failed = "configuration image $Config failed after $($attempts.Count) attempt(s)" }
}

# ------------------------------------------------------------ outputs, record, summary
$result.minutes = [math]::Round($total.Elapsed.TotalMinutes, 1)
$result.versions = '{}'
if ($result.build_id -and (Test-Path (Join-Path $sls "out/builds/$($result.build_id)/build.json"))) {
    $result.versions = (Get-Content (Join-Path $sls "out/builds/$($result.build_id)/build.json") -Raw | ConvertFrom-Json).versions | ConvertTo-Json -Compress -Depth 4
} elseif ($result.base_image) {
    $lbl = "$(& docker image inspect -f '{{json .Config.Labels}}' $result.base_image 2>$null)".Trim()
    if ($lbl -and $lbl -ne 'null') { $result.versions = $lbl }
}
$record.result = $result
$record.failed = $failed
New-Item -ItemType Directory -Force -Path (Join-Path $sls 'out') | Out-Null
$record | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $sls 'out/ci-build.json') -Encoding utf8
Write-CiOutput $result

$md = @('### SystemLink Server image', '')
$att = Join-Path $sls "out/builds/attempts-$BuildId.json"
if (Test-Path $att) {
    $md += '| base attempt | build | from | minutes | result | failed stage | bugcheck | message |', '|---|---|---|---|---|---|---|---|'
    foreach ($x in @(Get-Content $att -Raw | ConvertFrom-Json)) {
        $md += "| $($x.attempt) | $($x.buildId) | $($x.from) | $($x.minutes) | $($x.result) | $($x.stage) | $($x.bugcheck) | $("$($x.message)" -replace '\|', '/') |"
    }
    $md += ''
}
if ($result.build_id) {
    $bj = Join-Path $sls "out/builds/$($result.build_id)/build.json"
    if (Test-Path $bj) {
        $b = Get-Content $bj -Raw | ConvertFrom-Json
        $md += "Base stages (min): $(($b.stagesSec.PSObject.Properties | ForEach-Object { "$($_.Name) $([math]::Round($_.Value / 60, 1))" }) -join ', ')"
        $md += "Base image: ``$($b.image)``, $([math]::Round($b.sizes.imageBytes / 1GB, 2)) GB, disk layer $([math]::Round($b.sizes.qcow2Bytes / 1GB, 2)) GB; SystemLink $($b.versions.systemlinkServer)", ''
    }
} elseif ($BaseImage) { $md += "Base image: ``$BaseImage`` (not built)", '' }
if ($record.config) {
    $md += '| config attempt | minutes | result | bugcheck | message |', '|---|---|---|---|---|'
    foreach ($x in $record.config.attempts) { $md += "| $($x.attempt) | $($x.minutes) | $($x.result) | $($x['bugcheck']) | $("$($x['message'])" -replace '\|', '/') |" }
    $cj = Join-Path $sls "out/configs/$Config/config.json"
    if (Test-Path $cj) {
        $c = Get-Content $cj -Raw | ConvertFrom-Json
        $md += '', "Configuration image: ``$($c.tag)``, layer $([math]::Round($c.layerBytes / 1MB, 1)) MB; healthy $($c.healthySec) s, seed $($c.seedSec) s, seal $($c.sealSec) s, verify healthy $($c.verifyHealthySec) s, total $([math]::Round($c.totalSec / 60, 1)) min"
    }
    $md += ''
}
$md += $(if ($failed) { "**FAILED:** $failed" } else { "Result: ``$($result.image)`` ($($result.tags))" })
if ($env:GITHUB_STEP_SUMMARY) { $md -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 } else { $md -join "`n" | Write-Host }

if ($failed) { Write-Host "::error::$failed"; exit 1 }
Write-Host "image $($result.image) ($($result.tags))"
