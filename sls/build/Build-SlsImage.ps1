#Requires -Version 7.2
<#
.SYNOPSIS
Builds the SystemLink Server container image from nothing: unattended Windows Server + NI Package Manager + SystemLink
Server install in a dockurr/windows VM, seal, convert to a compressed qcow2, image layers, verification.

.DESCRIPTION
Stages: Install -> Seal -> Convert -> Image -> Verify. Work state lives in docker volumes sls-build-<id>-* and in
out\builds\<id> (context.json, build.log, credentials.json, install/seal reports, build.json). A failed build keeps its
state; resume with -BuildId <id> -From <stage>. A successful build removes the work volumes unless -Keep.

The web admin password is SLS_BUILD_ADMIN_PASSWORD when set, else generated; it is stored only in the git-ignored
out\builds\<id>\credentials.json. Consumers override it at run time with SLS_ADMIN_PASSWORD.

.EXAMPLE
pwsh build/Build-SlsImage.ps1
pwsh build/Build-SlsImage.ps1 -SlsVersion 26.5 -NipmVersion 26.8.0
pwsh build/Build-SlsImage.ps1 -BuildId 20261120-101500 -From Seal
pwsh build/Build-SlsImage.ps1 -BuildId 20261120-101500 -Cleanup
#>
[CmdletBinding()]
param(
    [string]$SlsVersion = '26.5',
    [string]$NipmVersion = '26.8.0',
    # Default: SystemLink Server plus the modules whose data the migration tooling covers (§ docs of the test plan).
    [string[]]$Packages = @('ni-systemlink-server', 'ni-systemlink-software-config-module', 'ni-systemlink-test-module', 'ni-systemlink-asset-module'),
    [string]$InstallFlags = '--accept-eulas --assume-yes --include-recommended',
    # Default: the released + released-critical feeds of -SlsVersion for each of -Packages (each is an NI product with
    # its own feed under products/ni-s/<package>).
    [string[]]$Feeds,
    [string]$WindowsVersion = '2022',
    [string]$DockurImage,
    [string]$Repository = 'sls-server',
    [string]$BuildId,
    [ValidateSet('Install', 'Seal', 'Convert', 'Image', 'Verify')][string]$From = 'Install',
    [ValidateSet('Install', 'Seal', 'Convert', 'Image', 'Verify')][string]$To = 'Verify',
    [string]$Ram = '16G',
    [int]$Cpu = 8,
    # Virtual size (sparse; does not change the image size). Containers can grow it with DISK_SIZE but Windows does not
    # extend its partition on its own.
    [string]$DiskSize = '128G',
    [string]$VmUser = 'Docker',
    [int]$InstallTimeoutMinutes = 150,
    # Publishes the dockur web viewer (VNC in the browser) on 127.0.0.1:<port> during Install and Seal.
    [int]$ViewerPort = 0,
    # PEM file with extra root certificates for the VM container's downloads (the Windows ISO) behind TLS-inspecting
    # proxies. Default: SLS_BUILD_CA_FILE. Not part of the image.
    [string]$CaCertFile = $env:SLS_BUILD_CA_FILE,
    # Preflight: free GB required in the Docker data root. Default: SLS_BUILD_MIN_FREE_GB, else 60 for a whole build
    # and less when resuming at a later stage (what the remaining stages still write).
    [int]$MinFreeGB = $(if ($env:SLS_BUILD_MIN_FREE_GB) { [int]$env:SLS_BUILD_MIN_FREE_GB } else { 0 }),
    # More tags for the image: a bare tag goes on -Repository, a full reference (repo:tag) is used as is.
    [string[]]$ExtraTag = @(),
    # User-based license files mounted into the Verify container only (never into the build VM or the image).
    [string[]]$LicenseFile = @(),
    [string]$LicenseUser = $env:SLS_LICENSE_USER,
    # Image stage gate: base.qcow2 (the disk layer) must not exceed this (GHCR rejects layers over 10 GB).
    [double]$MaxDiskLayerGB = 9.5,
    # Keeps dockur's Hyper-V enlightenments (HV=Y) in the build VM. Off by default: on nested KVM (WSL2 / Azure hosts)
    # they led to Windows bugchecks (stop 0x4A) during the seal. Default: SLS_BUILD_HYPERV=1. Applies at Install.
    [switch]$HyperV = $($env:SLS_BUILD_HYPERV -eq '1'),
    [switch]$Keep,
    [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SlsBuild.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'testkit\SlsTestKit.psm1') -Force
$StageNames = @('Install', 'Seal', 'Convert', 'Image', 'Verify')
$repo = Get-SlsRepoRoot

function Save-Context($Ctx) { $Ctx | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Ctx.OutDir 'context.json') -Encoding utf8 }

function Remove-BuildWork($Ctx) {
    Write-SlsLog "cleanup: container $($Ctx.Container), volumes $($Ctx.Volumes.PSObject.Properties.Value -join ', '), $($Ctx.DiskImage)"
    Remove-SlsContainer $Ctx.Container
    foreach ($v in $Ctx.Volumes.PSObject.Properties.Value) { & docker volume rm $v 2>&1 | Out-Null }
    # Only the tag: the layers stay referenced by the final image.
    if (Test-SlsImage $Ctx.DiskImage) { & docker rmi $Ctx.DiskImage 2>&1 | Out-Null }
}

# ---------------------------------------------------------------- context (new or resumed)
if ($BuildId -and (Test-Path (Join-Path $repo "out\builds\$BuildId\context.json"))) {
    $Ctx = Get-Content (Join-Path $repo "out\builds\$BuildId\context.json") -Raw | ConvertFrom-Json
    # ConvertFrom-Json turns ISO strings into local DateTime values; keep them ISO UTC.
    if ($Ctx.Started -is [datetime]) { $Ctx.Started = $Ctx.Started.ToUniversalTime().ToString('o') }
    Set-SlsLogFile (Join-Path $Ctx.OutDir 'build.log')
    if ($Cleanup) { Remove-BuildWork $Ctx; return }
    Write-SlsLog "resuming build $BuildId from $From (build parameters from context.json)"
} else {
    if ($Cleanup) { throw "no build $BuildId to clean up" }
    if ($From -ne 'Install') { throw "-From $From needs the -BuildId of an earlier build" }
    if (-not $BuildId) { $BuildId = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') }
    if (-not $DockurImage) { $DockurImage = Get-SlsDefaultDockurImage }
    if (-not $Feeds) {
        $Feeds = @(foreach ($p in $Packages) {
                $feedBase = "https://download.ni.com/support/nipkg/products/ni-s/$p/$SlsVersion"
                "$feedBase/released"; "$feedBase/released-critical"
            })
    }
    $outDir = Join-Path $repo "out\builds\$BuildId"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $Ctx = [pscustomobject]@{
        BuildId = $BuildId; OutDir = $outDir; Container = "sls-build-$BuildId"
        Volumes = [pscustomobject]@{ Storage = "sls-build-$BuildId-storage"; Shared = "sls-build-$BuildId-shared"; Images = "sls-build-$BuildId-images" }
        DiskImage = "sls-server-disk:$BuildId"; Repository = $Repository
        SlsVersion = $SlsVersion; NipmVersion = $NipmVersion; Packages = $Packages; InstallFlags = $InstallFlags; Feeds = $Feeds
        NipmUrl = "https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager$NipmVersion.exe"
        WindowsVersion = $WindowsVersion; DockurImage = $DockurImage; Ram = $Ram; Cpu = $Cpu; DiskSize = $DiskSize; VmUser = $VmUser
        InstallTimeoutMinutes = $InstallTimeoutMinutes; ViewerPort = $ViewerPort; HyperV = [bool]$HyperV
        Started = (Get-Date).ToUniversalTime().ToString('o'); Stages = [pscustomobject]@{}; Results = [pscustomobject]@{}
    }
    Set-SlsLogFile (Join-Path $outDir 'build.log')
    $credFile = Join-Path $outDir 'credentials.json'
    $adminPassword = if ($env:SLS_BUILD_ADMIN_PASSWORD) { $env:SLS_BUILD_ADMIN_PASSWORD } else { New-SlsPassword }
    # Git-ignored (out/). The VM account password is reset to an unstored random value by the seal.
    [ordered]@{ adminUser = 'admin'; adminPassword = $adminPassword; vmUser = $VmUser; vmPassword = (New-SlsPassword 'Vm-') } |
        ConvertTo-Json | Set-Content $credFile -Encoding utf8
    Save-Context $Ctx
    Write-SlsLog "build ${BuildId}: SystemLink Server $SlsVersion (NIPM $NipmVersion) on Windows Server $WindowsVersion -> $Repository"
}
if ($ViewerPort) { $Ctx.ViewerPort = $ViewerPort }
if ($PSBoundParameters.ContainsKey('MaxDiskLayerGB') -or -not $Ctx.PSObject.Properties['MaxDiskLayerGB']) {
    $Ctx | Add-Member -NotePropertyName MaxDiskLayerGB -NotePropertyValue $MaxDiskLayerGB -Force
}
$creds = Get-Content (Join-Path $Ctx.OutDir 'credentials.json') -Raw | ConvertFrom-Json
Register-SlsSecret $creds.adminPassword, $creds.vmPassword
if ($ExtraTag) { $Ctx | Add-Member -NotePropertyName ExtraTags -NotePropertyValue @($ExtraTag | ForEach-Object { Resolve-SlsTag $Ctx.Repository $_ }) -Force }
if ($LicenseFile) {
    $Ctx | Add-Member -NotePropertyName LicenseFiles -NotePropertyValue @($LicenseFile | ForEach-Object { (Resolve-Path $_ -ErrorAction Stop).Path }) -Force
}
if ($LicenseUser) { $Ctx | Add-Member -NotePropertyName LicenseUser -NotePropertyValue $LicenseUser -Force }
if ($CaCertFile) {
    if (-not (Test-Path $CaCertFile -PathType Leaf) -or -not (Select-String -Path $CaCertFile -Pattern '-----BEGIN CERTIFICATE-----' -Quiet)) {
        throw "-CaCertFile $CaCertFile is not a PEM certificate file"
    }
    $Ctx | Add-Member -NotePropertyName CaCertFile -NotePropertyValue (Resolve-Path $CaCertFile).Path -Force
}

# ---------------------------------------------------------------- preflight
if (-not $MinFreeGB) { $MinFreeGB = @{ Install = 60; Seal = 60; Convert = 35; Image = 25; Verify = 10 }[$From] }
try { $freeGB = Test-SlsDockerHost -MinFreeGB $MinFreeGB }
catch { Write-SlsLog "stage $From FAILED: preflight: $($_.Exception.Message)"; throw }
Write-SlsLog "preflight: docker ok, /dev/kvm ok, $freeGB GB free"
if ($From -eq 'Install') {
    foreach ($u in @($Ctx.NipmUrl) + @($Ctx.Feeds | ForEach-Object { "$_/Packages" })) {
        try { $null = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 30 }
        catch { throw "URL not reachable: $u ($($_.Exception.Message))" }
    }
    Write-SlsLog 'preflight: NIPM installer and feeds reachable'
}

# ---------------------------------------------------------------- stages
$first = [array]::IndexOf($StageNames, $From)
$last = [array]::IndexOf($StageNames, $To)
if ($last -lt $first) { throw "-To $To comes before -From $From" }
$failed = $null
foreach ($stage in $StageNames[$first..$last]) {
    Write-SlsLog "==== stage $stage"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & (Join-Path $PSScriptRoot "stages\$stage.ps1") -Ctx $Ctx
    } catch {
        $failed = $stage
        Write-SlsLog "stage $stage FAILED: $($_.Exception.Message)"
        Write-SlsLog "  at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
    }
    $Ctx.Stages | Add-Member -NotePropertyName $stage -NotePropertyValue ([math]::Round($sw.Elapsed.TotalSeconds)) -Force
    Save-Context $Ctx
    if ($failed) { break }
    Write-SlsLog "stage $stage done in $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
}

if ($failed) {
    Write-SlsLog "build $($Ctx.BuildId) failed in $failed. State kept (container $($Ctx.Container), volumes sls-build-$($Ctx.BuildId)-*)."
    Write-SlsLog "  resume:  pwsh build/Build-SlsImage.ps1 -BuildId $($Ctx.BuildId) -From $failed"
    Write-SlsLog "  cleanup: pwsh build/Build-SlsImage.ps1 -BuildId $($Ctx.BuildId) -Cleanup"
    exit 1
}

if ($To -eq 'Verify') {
    $Ctx | Add-Member -NotePropertyName Finished -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    Save-Context $Ctx
    $r = $Ctx.Results
    $build = [ordered]@{
        buildId = $Ctx.BuildId; started = $Ctx.Started; finished = $Ctx.Finished; stagesSec = $Ctx.Stages
        image = $r.Image; imageId = $r.ImageId; tags = $r.Tags; publishTags = $r.PublishTags
        versions = $r.Versions; sizes = $r.Sizes; verify = $r.Verify; dockurImage = $Ctx.DockurImage; git = $r.Git
    }
    $build | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Ctx.OutDir 'build.json') -Encoding utf8
    Write-SlsLog "build.json: $(Join-Path $Ctx.OutDir 'build.json')"
    Write-SlsCiOutput ([ordered]@{
            build_id = $Ctx.BuildId; image = $r.Image; image_id = $r.ImageId; tags = ($r.Tags -join ','); sls_full_version = "$($r.Versions.systemlinkServer)"
            disk_layer_bytes = $r.Sizes.qcow2Bytes; out_dir = $Ctx.OutDir
        })
    if ($Keep) { Write-SlsLog "work state kept (-Keep); remove with -BuildId $($Ctx.BuildId) -Cleanup" } else { Remove-BuildWork $Ctx }
    $stageMin = [math]::Round((($Ctx.Stages.PSObject.Properties.Value | Measure-Object -Sum).Sum) / 60, 1)
    Write-SlsLog "built $($r.Tags -join ', ') in $stageMin min (sum of the stage times)"
}
