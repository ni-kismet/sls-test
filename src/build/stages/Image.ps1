# Stage Image: disk layer image (dockur image + /images/base.qcow2 + state files; docker commit avoids a 10+ GB build
# context), then image/Dockerfile on top of it (start hook, healthcheck, sls-* tools, guest agent, labels) and tags.
param([Parameter(Mandatory)]$Ctx)
$ErrorActionPreference = 'Stop'
$repo = Get-SlsRepoRoot
$v = $Ctx.Results.Versions
if (-not $v) { throw 'no versions recorded; rerun from Install' }

# GHCR rejects layers over 10 GB; base.qcow2 is (almost all of) the disk layer and is already compressed.
$diskBytes = [int64]$Ctx.Results.Sizes.qcow2Bytes
$maxGB = if ($Ctx.PSObject.Properties['MaxDiskLayerGB'] -and $Ctx.MaxDiskLayerGB) { [double]$Ctx.MaxDiskLayerGB } else { 9.5 }
Write-SlsLog ("disk layer: base.qcow2 {0:N2} GB (limit {1} GB)" -f ($diskBytes / 1GB), $maxGB)
if ($diskBytes -gt $maxGB * 1GB) {
    throw ("base.qcow2 is {0:N2} GB, over -MaxDiskLayerGB {1}: trim the install (fewer -Packages, more seal cleanup) or split the disk into two layers (base + overlay qcow2)" -f ($diskBytes / 1GB), $maxGB)
}

$tmp = "sls-build-$($Ctx.BuildId)-mkdisk"
Remove-SlsContainer $tmp
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-SlsDocker create --name $tmp --entrypoint sh -v "$($Ctx.Volumes.Images):/src:ro" $Ctx.DockurImage -c `
    'set -e; mkdir -p /images/state /images/configs; cp /src/base.qcow2 /images/base.qcow2; cp /src/state/windows.* /images/state/; chmod 444 /images/base.qcow2; ls -la /images /images/state' | Out-Null
try {
    Invoke-SlsDocker start -a $tmp | ForEach-Object { Write-SlsLog "  $_" }
    Invoke-SlsDocker commit --change 'ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]' --change 'CMD []' `
        --change "LABEL com.ni.sls.build-id=$($Ctx.BuildId)" $tmp $Ctx.DiskImage | Out-Null
} finally { Remove-SlsContainer $tmp }
$diskSec = [math]::Round($sw.Elapsed.TotalSeconds)
Write-SlsLog "disk layer image $($Ctx.DiskImage) in $diskSec s"

$full = "$($v.systemlinkServer)"
if ($full -notmatch '^(\d+\.\d+\.\d+)') { throw "unexpected SystemLink Server version '$full'" }
$xyz = $matches[1]
# Unique per build (UTC minute): a same-day rebuild doesn't move an earlier build's dated tag.
$date = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmm')
$tags = @("$($Ctx.Repository):$xyz-$date", "$($Ctx.Repository):$($Ctx.SlsVersion)")
if ($Ctx.PSObject.Properties['ExtraTags']) { $tags += @($Ctx.ExtraTags | Where-Object { $_ -notin $tags }) }
$git = Get-SlsGitInfo
$adminPassword = (Get-Content (Join-Path $Ctx.OutDir 'credentials.json') -Raw | ConvertFrom-Json).adminPassword
# pwsh turns ISO date strings from JSON into DateTime; keep the label ISO 8601 (UTC).
$expires = $v.eval.expiresUtc
if ($expires -is [datetime]) { $expires = $expires.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
$products = if ($v.PSObject.Properties['products']) { ($v.products.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ',' } else { "ni-systemlink-server=$full" }
$buildArgs = [ordered]@{
    DISK_IMAGE = $Ctx.DiskImage; SLS_VERSION = $full; SLS_FEED_VERSION = $Ctx.SlsVersion; NIPM_VERSION = "$($v.nipm)"; SLS_PRODUCTS = $products
    WINDOWS_VERSION = "$($Ctx.WindowsVersion) ($($v.windows.build))"; WINDOWS_EVAL_EXPIRES = "$expires"
    DOCKUR_IMAGE = $Ctx.DockurImage; BUILD_ID = $Ctx.BuildId; CREATED = (Get-Date).ToUniversalTime().ToString('o')
    REVISION = $git.Revision; SOURCE = $git.Source
    # The default password is not a secret: sls-start-server skips the password change at start when it matches.
    ADMIN_PASSWORD_LABEL = $(if ($adminPassword -eq 'test') { 'test' } else { 'custom' })
}
$a = @('build')
foreach ($k in $buildArgs.Keys) { $a += @('--build-arg', "$k=$($buildArgs[$k])") }
foreach ($t in $tags) { $a += @('-t', $t) }
$a += (Join-Path $repo 'image')
$sw.Restart()
Invoke-SlsDocker @a | Out-Null
Write-SlsLog "built $($tags -join ', ') in $([math]::Round($sw.Elapsed.TotalSeconds)) s"

$imageId = "$(Invoke-SlsDocker image inspect -f '{{.Id}}' $tags[0])".Trim()
$size = [int64]"$(Invoke-SlsDocker image inspect -f '{{.Size}}' $tags[0])".Trim()
foreach ($h in (Invoke-SlsDocker history --format '{{.Size}}|{{.CreatedBy}}' $tags[0] | Select-Object -First 10)) {
    $s, $by = "$h" -split '\|', 2
    Write-SlsLog ("  layer {0,-8} {1}" -f $s, $by.Substring(0, [Math]::Min(100, $by.Length)))
}
$Ctx.Results | Add-Member -NotePropertyName Image -NotePropertyValue $tags[0] -Force
$Ctx.Results | Add-Member -NotePropertyName ImageId -NotePropertyValue $imageId -Force
$Ctx.Results | Add-Member -NotePropertyName Tags -NotePropertyValue $tags -Force
# For a registry push: immutable dated tag + floating tags.
$Ctx.Results | Add-Member -NotePropertyName PublishTags -NotePropertyValue @("$xyz-$date", $xyz, $Ctx.SlsVersion) -Force
$Ctx.Results | Add-Member -NotePropertyName Git -NotePropertyValue $git -Force
$Ctx.Results.Sizes | Add-Member -NotePropertyName imageBytes -NotePropertyValue $size -Force
$Ctx.Results.Sizes | Add-Member -NotePropertyName diskImageSec -NotePropertyValue $diskSec -Force
Write-SlsLog ("image {0}: {1:N2} GB, id {2}" -f $tags[0], ($size / 1GB), $imageId.Substring(0, 19))
