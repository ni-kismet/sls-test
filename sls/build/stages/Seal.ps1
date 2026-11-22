# Stage Seal: API probe, Seal-Vm.ps1 phase 1 (installer + secrets removed, autologon off, maintenance off, DISM,
# caches; reboot), then phase 2 (NI services stopped, MongoDB clean shutdown verified, logs cleared, retrim; power off).
param([Parameter(Mandatory)]$Ctx)
$ErrorActionPreference = 'Stop'
$c = $Ctx.Container
$creds = Get-Content (Join-Path $Ctx.OutDir 'credentials.json') -Raw | ConvertFrom-Json
$cred = New-SlsCredential $creds.adminUser $creds.adminPassword

if (-not (Test-SlsRunning $c)) {
    if (-not (Test-SlsContainer $c)) { throw "build container $c is missing; rerun from Install" }
    $prev = (Read-SlsSharedJson $c 'agent/ready.json')
    Write-SlsLog "starting the stopped build VM $c"
    Invoke-SlsDocker start $c | Out-Null
    Invoke-SlsDocker exec -d $c sls-smb-nolease -w 600 | Out-Null
    & docker exec -d $c sls-panic-watch 2>&1 | Out-Null
    $null = Wait-SlsAgentReady -Container $c -PreviousBootId $(if ($prev) { $prev.bootId } else { '' }) -TimeoutSec 1200
}
$server = Get-SlsServer -Name $c -Credential $cred

# The API shapes used by verification and configuration seeds work on the installed server; the probe tag is deleted.
$err = Test-SlsTagRoundTrip -Server $server -Path 'slsbuild.seal.probe' -Value 42.5 -Delete
if ($err) { throw "tag round trip before sealing failed: $err" }
Write-SlsLog 'pre-seal API probe: tag create/write/read/delete ok'

$sealDir = Join-Path $Ctx.OutDir 'seal'
New-Item -ItemType Directory -Force -Path $sealDir | Out-Null
$prev = (Read-SlsSharedJson $c 'agent/ready.json').bootId
$code = Invoke-SlsGuestScript -Container $c -Label 'seal1' -TimeoutSec 5400 -OutFile (Join-Path $sealDir 'phase1.out.txt') `
    -Script "& 'C:\sls\guest\Seal-Vm.ps1' -Phase 1; exit `$LASTEXITCODE"
if ($code -ne 0) { throw "seal phase 1 failed (exit $code)" }
$sw = [Diagnostics.Stopwatch]::StartNew()
$ready = Wait-SlsAgentReady -Container $c -PreviousBootId $prev -TimeoutSec 1800
Write-SlsLog "rebooted after seal phase 1: ready after $([math]::Round($sw.Elapsed.TotalSeconds)) s (services $($ready.servicesSinceBootSec)s after boot)"

$code = Invoke-SlsGuestScript -Container $c -Label 'seal2' -TimeoutSec 1200 -OutFile (Join-Path $sealDir 'phase2.out.txt') `
    -Script "& 'C:\sls\guest\Seal-Vm.ps1' -Phase 2; exit `$LASTEXITCODE"
if ($code -ne 0) { throw "seal phase 2 failed (exit $code); VM left running for inspection" }
if (-not (Wait-SlsExit $c 900)) { throw 'VM did not power off within 15 minutes after seal phase 2' }
$exit = "$(& docker inspect -f '{{.State.ExitCode}}' $c)".Trim()
& docker cp "${c}:/shared/seal/." $sealDir 2>&1 | Out-Null
& docker logs -t $c *> (Join-Path $Ctx.OutDir 'container-seal.log')
if ($exit -ne '0') { throw "build container exited with $exit after the seal" }

$p2 = Get-Content (Join-Path $sealDir 'phase2.json') -Raw | ConvertFrom-Json
foreach ($s in $p2.steps | Where-Object { $_.error }) { Write-SlsLog "seal phase 2 step $($s.name): $($s.error)" }
$p1 = Get-Content (Join-Path $sealDir 'phase1.json') -Raw | ConvertFrom-Json
$Ctx.Results | Add-Member -NotePropertyName Seal -NotePropertyValue ([pscustomobject]@{
        phase1Sec = $p1.totalSec; phase2Sec = $p2.totalSec; rebootToReadySec = [math]::Round($sw.Elapsed.TotalSeconds)
        dataImgAllocatedBytes = Get-SlsVolumeUsageBytes $Ctx.Volumes.Storage 'data.img'
    }) -Force
Write-SlsLog "sealed: phase 1 $($p1.totalSec)s, phase 2 $($p2.totalSec)s, data.img allocated $([math]::Round($Ctx.Results.Seal.dataImgAllocatedBytes / 1GB, 2)) GB"
