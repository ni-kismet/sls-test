# Stage Install: unattended Windows Server install in the pinned dockur image, then (first logon, C:\OEM\install.bat)
# Install-Sls.ps1 as a SYSTEM startup task: NIPM, feeds, SystemLink Server, web server setup, guest agent.
# Ends when install.done says completed and the guest agent reports ready.
param([Parameter(Mandatory)]$Ctx)
$ErrorActionPreference = 'Stop'
$repo = Get-SlsRepoRoot
$c = $Ctx.Container
$creds = Get-Content (Join-Path $Ctx.OutDir 'credentials.json') -Raw | ConvertFrom-Json

# ---------------------------------------------------------------- OEM folder (copied into the VM as C:\OEM)
$oem = Join-Path $Ctx.OutDir 'oem'
Remove-Item $oem -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$oem\sls" | Out-Null
Copy-Item (Join-Path $repo 'build\guest\install.bat') $oem
Copy-Item (Join-Path $repo 'build\guest\*.ps1') "$oem\sls"
[ordered]@{
    nipmUrl = $Ctx.NipmUrl; nipmInstallArgs = '--passive --accept-eulas --prevent-reboot'
    feeds = @($Ctx.Feeds); packages = @($Ctx.Packages); installFlags = $Ctx.InstallFlags
    installTimeoutMinutes = 120; maxReboots = 4
    adminUser = $creds.adminUser; adminPassword = $creds.adminPassword
    webServerSetupArgs = 'setup insecure-remote --admin-pass pass:{adminPassword} --yes --port 80 --finish --no-interactive'
} | ConvertTo-Json -Depth 4 | Set-Content "$oem\sls\config.json" -Encoding ascii

# ---------------------------------------------------------------- VM container
Remove-SlsContainer $c
foreach ($v in $Ctx.Volumes.Storage, $Ctx.Volumes.Shared) { & docker volume rm $v 2>&1 | Out-Null; Invoke-SlsDocker volume create $v | Out-Null }
$a = @('create', '--name', $c, '--device', '/dev/kvm', '--device', '/dev/net/tun', '--cap-add', 'NET_ADMIN', '--stop-timeout', '150',
    '-e', "VERSION=$($Ctx.WindowsVersion)", '-e', "RAM_SIZE=$($Ctx.Ram)", '-e', "CPU_CORES=$($Ctx.Cpu)", '-e', "DISK_SIZE=$($Ctx.DiskSize)",
    '-e', "USERNAME=$($Ctx.VmUser)", '-e', 'PASSWORD', '-p', '127.0.0.1::80',
    # A Windows bugcheck pauses the VM (sls-panic-watch reports it) instead of QEMU's default: exit 0, no dump, which
    # looks like a clean power off. With HV=N, hv-crash alone lets Windows report the bugcheck to QEMU.
    '-e', 'ARGUMENTS=-action panic=pause')
$a += if ($Ctx.PSObject.Properties['HyperV'] -and $Ctx.HyperV) { @('-e', 'HV=Y') } else { @('-e', 'HV=N', '-e', 'CPU_FLAGS=hv-crash') }
$a += @(
    '-v', "$($Ctx.Volumes.Storage):/storage", '-v', "$($Ctx.Volumes.Shared):/shared",
    '--label', "com.ni.sls.build-id=$($Ctx.BuildId)")
if ($Ctx.ViewerPort) { $a += @('-p', "127.0.0.1:$($Ctx.ViewerPort):8006") }
$a += $Ctx.DockurImage
$env:PASSWORD = $creds.vmPassword
try { Invoke-SlsDocker @a | Out-Null } finally { Remove-Item Env:PASSWORD -ErrorAction SilentlyContinue }
if ($Ctx.PSObject.Properties['CaCertFile'] -and $Ctx.CaCertFile) {
    # dockur downloads the ISO with the system bundle; append the extra roots before the first start.
    $bundle = Join-Path $Ctx.OutDir 'ca-certificates.crt'
    Invoke-SlsDocker cp "${c}:/etc/ssl/certs/ca-certificates.crt" $bundle | Out-Null
    Add-Content -Path $bundle -Value ("`n" + (Get-Content $Ctx.CaCertFile -Raw)) -NoNewline
    Invoke-SlsDocker cp $bundle "${c}:/etc/ssl/certs/ca-certificates.crt" | Out-Null
    Write-SlsLog "extra CA certificates from $($Ctx.CaCertFile) trusted for the VM container's downloads"
}
# Copied rather than bind-mounted: a bind mount whose source is gone (removed below; Docker Desktop's WSL bind
# paths only exist for the creating session) makes the stopped container impossible to restart on resume.
Invoke-SlsDocker cp "$oem/." "${c}:/oem" | Out-Null
Remove-Item $oem -Recurse -Force
# Build-time tools (the plain dockur image has none of them): sls-exec for the seal, the Samba lease fix.
Invoke-SlsDocker cp (Join-Path $repo 'image\bin\.') "${c}:/usr/local/bin/" | Out-Null
Invoke-SlsDocker cp (Join-Path $repo 'image\guest\.') "${c}:/shared/guest" | Out-Null
Invoke-SlsDocker start $c | Out-Null
Invoke-SlsDocker exec $c sh -c 'chmod 755 /usr/local/bin/sls-*' | Out-Null
Invoke-SlsDocker exec -d $c sls-smb-nolease -w 3600 | Out-Null
Invoke-SlsDocker exec -d $c sls-panic-watch | Out-Null
Write-SlsLog "VM $c started: Windows Server $($Ctx.WindowsVersion), $($Ctx.Cpu) cores, $($Ctx.Ram), $($Ctx.DiskSize), Hyper-V enlightenments $(if ($Ctx.HyperV) { 'on' } else { 'off' })$(if ($Ctx.ViewerPort) { ", viewer http://127.0.0.1:$($Ctx.ViewerPort)" })"

# ---------------------------------------------------------------- wait for the install
function Save-InstallReports {
    $dest = Join-Path $Ctx.OutDir 'install'
    Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue
    & docker cp "${c}:/shared/install" $dest 2>&1 | Out-Null
    & docker cp "${c}:/shared/agent" (Join-Path $Ctx.OutDir 'agent') 2>&1 | Out-Null
    & docker logs -t $c *> (Join-Path $Ctx.OutDir 'container-install.log')
}

$deadline = (Get-Date).AddMinutes($Ctx.InstallTimeoutMinutes)
$lastLine = ''
$lastStatus = ''
$done = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
while ((Get-Date) -lt $deadline) {
    if (-not (Test-SlsRunning $c)) {
        Save-InstallReports
        $hint = if (Select-String -Path (Join-Path $Ctx.OutDir 'container-install.log') -Pattern 'TLS handshake failure|issuer is not known' -Quiet) {
            ' The Windows ISO download failed TLS verification (TLS-inspecting proxy?): pass the proxy root CA with -CaCertFile / SLS_BUILD_CA_FILE.'
        }
        throw "VM container stopped during the install; see $(Join-Path $Ctx.OutDir 'container-install.log').$hint"
    }
    Assert-SlsNoGuestPanic $c
    $done = Read-SlsShared $c 'install/install.done'
    if ($done) { break }
    $s = Read-SlsSharedJson $c 'install/status.json'
    if ($s) {
        $line = "install: $($s.current) | " + (($s.steps.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.status)" }) -join ' ')
        if ($line -ne $lastStatus) { Write-SlsLog $line; $lastStatus = $line }
    } else {
        # Still installing Windows: show dockur's progress messages.
        $log = "$(& docker logs --tail 1 $c 2>&1 | Select-Object -Last 1)".Trim()
        if ($log -and $log -ne $lastLine) { Write-SlsLog "windows: $log"; $lastLine = $log }
    }
    Start-Sleep -Seconds 20
}
if (-not $done) { Save-InstallReports; throw "install not finished after $($Ctx.InstallTimeoutMinutes) minutes" }
$done = $done.Trim()
Write-SlsLog "install.done: $done after $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
if ($done -ne 'completed') { Save-InstallReports; throw "install $done; reports in $(Join-Path $Ctx.OutDir 'install')" }

$ready = Wait-SlsAgentReady -Container $c -TimeoutSec 900
Write-SlsLog "guest agent ready (boot $($ready.bootId), services $($ready.servicesSinceBootSec)s, http $($ready.httpSinceBootSec)s after boot)"
Save-InstallReports

$versions = Get-Content (Join-Path $Ctx.OutDir 'install\versions.json') -Raw | ConvertFrom-Json
$status = Get-Content (Join-Path $Ctx.OutDir 'install\status.json') -Raw | ConvertFrom-Json
$Ctx.Results | Add-Member -NotePropertyName Versions -NotePropertyValue $versions -Force
$Ctx.Results | Add-Member -NotePropertyName InstallSteps -NotePropertyValue ([pscustomobject]@{
        minutes = [math]::Round($sw.Elapsed.TotalMinutes, 1); reboots = $status.reboots
        steps = ($status.steps.PSObject.Properties | ForEach-Object { [pscustomobject]@{ name = $_.Name; sec = $_.Value.sec } })
    }) -Force
$expires = $versions.eval.expiresUtc
if ($expires -is [datetime]) { $expires = $expires.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
Write-SlsLog "installed SystemLink Server $($versions.systemlinkServer), NIPM $($versions.nipm), Windows $($versions.windows.build), eval expires $expires"
if ($versions.PSObject.Properties['products']) {
    foreach ($p in $versions.products.PSObject.Properties) { Write-SlsLog "  product $($p.Name) $($p.Value)" }
}
