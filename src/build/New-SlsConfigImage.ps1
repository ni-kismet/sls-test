#Requires -Version 7.2
<#
.SYNOPSIS
Builds a SystemLink Server configuration image: a base image plus a thin qcow2 layer with preloaded data.

.DESCRIPTION
Seed mode (-Seed):        persistent work container from -BaseImage -> healthy -> seed script creates the data.
FromVolume mode:          copies an existing persistent container volume (created from -BaseImage; data entered by
                          hand or by other tools) into a work volume and boots it once (the user's volume is untouched).
Then: light seal through sls-exec (Seal-Vm.ps1 -Phase 1 -Light, -Phase 2 -NoRetrim: NI services stopped, MongoDB
clean shutdown verified, logs cleared, power off) -> qemu-img convert -B /images/base.qcow2 (zstd) ->
out\configs\<name>\<name>.qcow2 -> docker build image\config.Dockerfile -> verify (ephemeral start; the seed's -Verify).

Seed script contract: param([string]$BaseUrl, [pscredential]$Credential, [string]$Container, [switch]$Verify).
Without -Verify it creates data; with -Verify it throws when the data is missing. testkit\SlsTestKit.psm1 is loaded
(Get-SlsServer -Name $Container -Credential $Credential gives the object Invoke-SlsApi / Invoke-SlsGuest take).

The admin credential of the base image comes from SLS_BUILD_ADMIN_PASSWORD or the base build's credentials.json.

.EXAMPLE
pwsh build/New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name demo -Seed configs/demo/Seed.ps1
pwsh build/New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name mydata -FromVolume my-dev-volume
#>
[CmdletBinding(DefaultParameterSetName = 'Seed')]
param(
    [Parameter(Mandatory)][string]$BaseImage,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9_-]{0,39}$')][string]$Name,
    [Parameter(Mandatory, ParameterSetName = 'Seed')][string]$Seed,
    [Parameter(Mandatory, ParameterSetName = 'FromVolume')][string]$FromVolume,
    # Default: <base repository>:<base tag>-<name>
    [string]$Tag,
    # More tags: a bare tag goes on the repository of -Tag, a full reference (repo:tag) is used as is.
    [string[]]$ExtraTag = @(),
    # User-based license files for the work and verify containers (seeding modules that need a license). The seal
    # removes the files the agent placed, so they are not part of the configuration layer.
    [string[]]$LicenseFile = @(),
    # Windows user the user-based license is issued to (created in the guest; removed again by the seal).
    [string]$LicenseUser = $env:SLS_LICENSE_USER,
    [string]$Ram = '8G',
    [int]$Cpu = 4,
    [switch]$SkipVerify,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SlsBuild.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'testkit\SlsTestKit.psm1') -Force -Global
$repo = Get-SlsRepoRoot

if (-not (Test-SlsImage $BaseImage)) { throw "base image $BaseImage not found" }
if ($Seed) { $Seed = (Resolve-Path $Seed).Path }
# pwsh -File passes an array as one comma-separated string.
$ExtraTag = @($ExtraTag | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$LicenseFile = @($LicenseFile | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { (Resolve-Path $_ -ErrorAction Stop).Path })
if (-not $Tag) {
    $i = $BaseImage.LastIndexOf(':')
    $Tag = if ($i -gt $BaseImage.LastIndexOf('/')) { "$($BaseImage.Substring(0, $i)):$($BaseImage.Substring($i + 1))-$Name" } else { "${BaseImage}:latest-$Name" }
}
$tagRepo = $Tag.Substring(0, $Tag.LastIndexOf(':'))
$extraTags = @($ExtraTag | ForEach-Object { Resolve-SlsTag $tagRepo $_ } | Where-Object { $_ -ne $Tag })
$id = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$outDir = Join-Path $repo "out\configs\$Name"
Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Set-SlsLogFile (Join-Path $outDir 'config.log')
$work = "sls-config-$Name-$id"
$vol = "$work-storage"
$cred = Get-SlsImageCredential -Image $BaseImage
$total = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{ name = $Name; tag = $Tag; baseImage = $BaseImage; baseImageId = "$(Invoke-SlsDocker image inspect -f '{{.Id}}' $BaseImage)".Trim()
    source = $(if ($Seed) { "seed:$([IO.Path]::GetRelativePath($repo, $Seed) -replace '\\', '/')" } else { "volume:$FromVolume" }) }
Write-SlsLog "config $Name from $BaseImage ($($result.source)) -> $Tag"

function Save-WorkLogs([string]$Container) {
    & docker logs -t $Container *> (Join-Path $outDir "container-$Container.log")
    try { Save-SlsLogs $Container -Path $outDir -TimeoutSec 300 | Out-Null } catch { Write-SlsLog "log collection failed: $($_.Exception.Message)" }
}

try {
    # ------------------------------------------------------------ work volume
    & docker volume rm $vol 2>&1 | Out-Null
    Invoke-SlsDocker volume create $vol | Out-Null
    if ($FromVolume) {
        $users = "$(& docker ps -q --filter "volume=$FromVolume")".Trim()
        if ($users) { throw "volume $FromVolume is in use by a running container; stop it first (docker stop -t 150 ...)" }
        $out = Invoke-SlsHelper -Volumes @("${FromVolume}:/src:ro", "${vol}:/dst") -Script @'
set -e
test -s /src/data.qcow2 || { echo "no data.qcow2: not a persistent SystemLink Server container volume"; exit 3; }
qemu-img info --output=json /src/data.qcow2 | jq -r '"backing: " + (."backing-filename" // "none")'
cp -a /src/data.qcow2 /src/windows.* /dst/
du -sh /dst/data.qcow2
'@
        $out | ForEach-Object { Write-SlsLog "  $_" }
        $backing = "$($out | Select-String '^backing: ')" -replace '^backing: '
        if ($backing -notmatch '^/images/(base|configs/[^/]+)\.qcow2$') { throw "volume $FromVolume does not come from a SystemLink Server image (backing '$backing')" }
        try { Invoke-SlsHelper -Image $BaseImage -Script "test -f '$backing'" | Out-Null }
        catch { throw "volume $FromVolume is based on $backing, which $BaseImage does not contain; use the image the volume was created from" }
    }

    # ------------------------------------------------------------ boot, seed
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $server = Start-SlsServer -Image $BaseImage -Name $work -Credential $cred -Volume $vol -Ram $Ram -Cpu $Cpu -LicenseFile $LicenseFile -LicenseUser $LicenseUser -TimeoutSec 900
    $result.healthySec = [math]::Round($sw.Elapsed.TotalSeconds)
    Write-SlsLog "work container $work healthy after $($result.healthySec) s"
    if ($Seed) {
        $sw.Restart()
        & $Seed -BaseUrl $server.BaseUrl -Credential $cred -Container $work
        & $Seed -BaseUrl $server.BaseUrl -Credential $cred -Container $work -Verify
        $result.seedSec = [math]::Round($sw.Elapsed.TotalSeconds)
        Write-SlsLog "seeded and verified in $($result.seedSec) s"
    }

    # ------------------------------------------------------------ light seal
    $sw.Restart()
    # This checkout's seal, not the base image's copy: the agent mirrors /shared/guest to C:\sls\guest before each
    # command, so seal fixes reach configuration builds on an existing base image.
    Invoke-SlsDocker cp (Join-Path $repo 'image\guest\Seal-Vm.ps1') "${work}:/shared/guest/Seal-Vm.ps1" | Out-Null
    $code = Invoke-SlsGuestScript -Container $work -Label 'seal' -TimeoutSec 1200 -OutFile (Join-Path $outDir 'seal.out.txt') `
        -Script "& 'C:\sls\guest\Seal-Vm.ps1' -Phase 1 -Light; if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; & 'C:\sls\guest\Seal-Vm.ps1' -Phase 2 -NoRetrim; exit `$LASTEXITCODE"
    if ($code -ne 0) { Save-WorkLogs $work; throw "light seal failed (exit $code)" }
    if (-not (Wait-SlsExit $work 600)) { Save-WorkLogs $work; throw 'work VM did not power off after the seal' }
    $result.sealSec = [math]::Round($sw.Elapsed.TotalSeconds)
    & docker logs -t $work *> (Join-Path $outDir 'container-work.log')
    Remove-SlsContainer $work

    # ------------------------------------------------------------ rebase onto the image's base disk
    $sw.Restart()
    $out = Invoke-SlsHelper -Image $BaseImage -Volumes @("${vol}:/storage:ro", "${outDir}:/o") -Script (
        "set -e; qemu-img convert -W -m 8 -c -o compression_type=zstd -O qcow2 -B /images/base.qcow2 -F qcow2 /storage/data.qcow2 /tmp/$Name.qcow2; " +
        "qemu-img check -q /tmp/$Name.qcow2; echo 'check ok'; cp /tmp/$Name.qcow2 /o/$Name.qcow2; qemu-img info --output=json /o/$Name.qcow2")
    $info = ($out | Select-Object -Skip 1) -join "`n" | ConvertFrom-Json
    $result.rebaseSec = [math]::Round($sw.Elapsed.TotalSeconds)
    $result.layerBytes = (Get-Item (Join-Path $outDir "$Name.qcow2")).Length
    Write-SlsLog ("{0}.qcow2: {1:N1} MB on {2} ({3}) in {4} s" -f $Name, ($result.layerBytes / 1MB), $info.'backing-filename', "$($out | Select-Object -First 1)".Trim(), $result.rebaseSec)

    # ------------------------------------------------------------ image
    $sw.Restart()
    Invoke-SlsDocker build -f (Join-Path $repo 'image\config.Dockerfile') --build-arg "BASE_IMAGE=$BaseImage" --build-arg "CONFIG_NAME=$Name" `
        --build-arg "CONFIG_CREATED=$((Get-Date).ToUniversalTime().ToString('o'))" --build-arg "CONFIG_SOURCE=$($result.source)" -t $Tag $outDir | Out-Null
    foreach ($t in $extraTags) { Invoke-SlsDocker tag $Tag $t | Out-Null }
    $result.tags = @($Tag) + $extraTags
    $result.imageId = "$(Invoke-SlsDocker image inspect -f '{{.Id}}' $Tag)".Trim()
    Write-SlsLog "built $($result.tags -join ', ') in $([math]::Round($sw.Elapsed.TotalSeconds)) s"

    # ------------------------------------------------------------ verify
    if (-not $SkipVerify) {
        $sw.Restart()
        $v = Start-SlsServer -Image $Tag -Name "$work-verify" -Credential $cred -Ram $Ram -Cpu $Cpu -LicenseFile $LicenseFile -LicenseUser $LicenseUser -TimeoutSec 900
        try {
            $result.verifyHealthySec = [math]::Round($sw.Elapsed.TotalSeconds)
            $hook = (& docker logs $v.Name 2>&1 | Select-String '\[sls\] .*(ephemeral overlay|disk ready)' | ForEach-Object { "$_".Trim() }) -join ' | '
            if ($hook -notmatch "configs/$Name\.qcow2") { throw "verify container did not boot configs/$Name.qcow2: $hook" }
            if ($Seed) { & $Seed -BaseUrl $v.BaseUrl -Credential $cred -Container $v.Name -Verify }
            Write-SlsLog "verified $Tag (healthy after $($result.verifyHealthySec) s$(if ($Seed) { ', seed data present' }))"
        } catch { Save-WorkLogs $v.Name; throw }
        finally { Stop-SlsServer $v }
    }
} finally {
    if (-not $Keep) {
        Remove-SlsContainer $work
        & docker volume rm $vol 2>&1 | Out-Null
    } else { Write-SlsLog "kept work volume $vol" }
}
$result.totalSec = [math]::Round($total.Elapsed.TotalSeconds)
$result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir 'config.json') -Encoding utf8
Write-SlsCiOutput ([ordered]@{ image = $Tag; image_id = $result.imageId; tags = ($result.tags -join ','); layer_bytes = $result.layerBytes; out_dir = $outDir })
Write-SlsLog "config image $Tag done in $([math]::Round($total.Elapsed.TotalMinutes, 1)) min ($(Join-Path $outDir 'config.json'))"
