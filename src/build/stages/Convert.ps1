# Stage Convert: sealed raw disk (data.img) -> zstd-compressed qcow2 (base.qcow2) plus dockur's VM state files
# (windows.*: boot mode, NVRAM, MAC) in the images work volume.
param([Parameter(Mandatory)]$Ctx)
$ErrorActionPreference = 'Stop'
$state = "$(& docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' $Ctx.Container 2>$null)".Trim()
if ($state -ne 'false 0') { throw "build VM $($Ctx.Container) must have powered off cleanly after the seal (state: '$state')" }
& docker volume rm $Ctx.Volumes.Images 2>&1 | Out-Null
Invoke-SlsDocker volume create $Ctx.Volumes.Images | Out-Null
$vols = @("$($Ctx.Volumes.Storage):/s:ro", "$($Ctx.Volumes.Images):/i")
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-SlsHelper -Volumes $vols -Script @'
set -e
mkdir -p /i/state
cp -p /s/windows.* /i/state/
qemu-img convert -W -m 8 -c -o compression_type=zstd -f raw -O qcow2 /s/data.img /i/base.qcow2.tmp
mv /i/base.qcow2.tmp /i/base.qcow2
qemu-img check /i/base.qcow2 | tail -2
ls -la /i /i/state
'@ | ForEach-Object { Write-SlsLog "  $_" }
$info = Invoke-SlsHelper -Volumes $vols -Script 'qemu-img info --output=json /i/base.qcow2' | Out-String | ConvertFrom-Json
$Ctx.Results | Add-Member -NotePropertyName Sizes -NotePropertyValue ([pscustomobject]@{
        qcow2Bytes = [int64]$info.'actual-size'; virtualBytes = [int64]$info.'virtual-size'; convertSec = [math]::Round($sw.Elapsed.TotalSeconds)
    }) -Force
Write-SlsLog ("base.qcow2: {0:N2} GB (virtual {1:N0} GB) in {2}s" -f ($info.'actual-size' / 1GB), ($info.'virtual-size' / 1GB), $Ctx.Results.Sizes.convertSec)
