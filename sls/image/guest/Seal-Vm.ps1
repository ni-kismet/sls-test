# SystemLink Server image seal, run in the guest through the agent command channel (as SYSTEM).
#   -Phase 1: remove the build installer and its secrets, turn off autologon and reset the VM account password,
#             disable background maintenance, purge caches, component store cleanup, then reboot.
#   -Phase 2: stop NI services cleanly, clear logs, trim, then power off (the container exits with the VM).
#             -NoRetrim skips the full-volume retrim (configuration layers: a retrim of an overlay disk only adds
#             zero-cluster metadata; deletes are already trimmed online).
#   -Light:   configuration images: phase 1 only removes transient files (no Windows changes, no DISM, no reboot
#             needed; run phase 2 right after).
# Per-step timings and free space go to \\host.lan\Data\seal\phase<N>.json.
# Must stay compatible with Windows PowerShell 5.1 and ASCII-only.
param([Parameter(Mandatory)][ValidateSet(1, 2)][int]$Phase, [switch]$NoRetrim, [switch]$Light)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Share = '\\host.lan\Data'
$Steps = New-Object System.Collections.ArrayList
$SealStart = Get-Date
$SealSw = [Diagnostics.Stopwatch]::StartNew()

function Get-FreeBytes { [int64](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace }

function Save-Report([string]$Status) {
    $o = [ordered]@{ phase = $Phase; light = [bool]$Light; status = $Status; startUtc = $SealStart.ToUniversalTime().ToString('o')
        totalSec = [math]::Round($SealSw.Elapsed.TotalSeconds, 1); steps = $Steps }
    New-Item -ItemType Directory -Force -Path "$Share\seal" -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path "$Share\seal\phase$Phase.json" -Value ($o | ConvertTo-Json -Depth 4) -Encoding ascii
}

function Step([string]$Name, [scriptblock]$Body) {
    # Stopwatch, not wall clock: the time zone change in phase 1 shifts the clock.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $before = Get-FreeBytes
    $err = $null
    Write-Output "== $Name"
    try { & $Body 2>&1 | ForEach-Object { Write-Output "   $_" } } catch { $err = $_.Exception.GetBaseException().Message; Write-Output "   ERROR $err" }
    $after = Get-FreeBytes
    [void]$Steps.Add([ordered]@{ name = $Name; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        freeBeforeBytes = $before; freeAfterBytes = $after; freedBytes = $after - $before; error = $err })
    Save-Report 'running'
}

function Remove-Contents([string[]]$Paths) {
    foreach ($p in $Paths) {
        if (Test-Path $p) { Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Disable-Tasks([string]$TaskPath) {
    Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | ForEach-Object {
        try { Disable-ScheduledTask -InputObject $_ -ErrorAction Stop | Out-Null; "disabled $($_.TaskPath)$($_.TaskName)" }
        catch { "could not disable $($_.TaskPath)$($_.TaskName)" }
    }
}

function Set-RegDword([string]$Key, [string]$Name, [int]$Value) {
    # New-Item -Force on an existing registry key would recreate it and drop its values.
    if (-not (Test-Path $Key)) { New-Item -Path $Key -Force | Out-Null }
    Set-ItemProperty -Path $Key -Name $Name -Value $Value -Type DWord
}

function Set-ServiceStartDisabled([string]$Name) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path $key)) { "$Name missing"; return }
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    # Registry write works for protected services (WaaSMedicSvc) where Set-Service is denied.
    Set-ItemProperty -Path $key -Name Start -Value 4 -Type DWord
    "$Name Start=4"
}

function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return 'Vm-' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })) + '!7b'
}

function Remove-RuntimePlaced {
    # License files and license users the agent added at run time (Agent.ps1 $PlacedList).
    $list = 'C:\sls\runtime-placed.txt'
    if (-not (Test-Path $list)) { 'nothing placed at run time'; return }
    foreach ($line in @(Get-Content $list | Where-Object { $_ } | Select-Object -Unique)) {
        $kind, $value = $line -split ':', 2
        if ($kind -eq 'file' -and (Test-Path -LiteralPath $value)) { Remove-Item -LiteralPath $value -Force; "removed $value" }
        elseif ($kind -eq 'user' -and (Get-LocalUser -Name $value -ErrorAction SilentlyContinue)) {
            Remove-LocalUser -Name $value
            # A profile exists only if the user ever logged on.
            Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -match "\\$([regex]::Escape($value))$" } | Remove-CimInstance -ErrorAction SilentlyContinue
            "removed user $value"
        }
    }
    Remove-Item $list -Force
}

if ($Phase -eq 1 -and $Light) {
    Step 'remove-runtime-licenses' { Remove-RuntimePlaced }
    Step 'transient-files' {
        Remove-Contents @('C:\Windows\Temp', $env:TEMP)
        Get-ChildItem -Path 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-Contents @("$($_.FullName)\AppData\Local\Temp") }
    }
    Save-Report 'done'
    exit 0
}

if ($Phase -eq 1) {
    Step 'remove-runtime-licenses' { Remove-RuntimePlaced }
    Step 'remove-installer' {
        # C:\OEM\sls\config.json holds the build admin password; Panther keeps the unattend (VM account password).
        Unregister-ScheduledTask -TaskName 'SLS-Install' -Confirm:$false -ErrorAction SilentlyContinue
        foreach ($p in 'C:\OEM', 'C:\sls-install') { if (Test-Path $p) { Remove-Item -Path $p -Recurse -Force; "removed $p" } }
        Get-ChildItem -Path 'C:\Windows\Panther' -Filter '*.xml' -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)unattend' } | ForEach-Object { Remove-Item $_.FullName -Force; "removed $($_.FullName)" }
    }
    Step 'autologon-off' {
        # The build needed one interactive logon (OEM install.bat); the runtime agent runs as SYSTEM at startup.
        $w = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $user = (Get-ItemProperty $w -Name DefaultUserName -ErrorAction SilentlyContinue).DefaultUserName
        Set-ItemProperty -Path $w -Name AutoAdminLogon -Value '0'
        foreach ($n in 'DefaultPassword', 'AutoLogonCount') { Remove-ItemProperty -Path $w -Name $n -ErrorAction SilentlyContinue }
        if ($user -and (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
            # Random and not stored: the image carries no usable VM account password.
            Set-LocalUser -Name $user -Password (ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force)
            "autologon off; password of '$user' reset"
        } else { "autologon off; no local user '$user'" }
    }
    Step 'windows-update-off' {
        foreach ($s in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc') { Set-ServiceStartDisabled $s }
        $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
        Set-RegDword $au NoAutoUpdate 1
        Set-RegDword $au AUOptions 1
        Disable-Tasks '\Microsoft\Windows\WindowsUpdate\'
        Disable-Tasks '\Microsoft\Windows\UpdateOrchestrator\'
        Disable-Tasks '\Microsoft\Windows\WaaSMedic\'
    }
    Step 'background-maintenance-off' {
        Disable-Tasks '\Microsoft\Windows\Windows Defender\'
        Disable-Tasks '\Microsoft\Windows\Defrag\'
        Disable-Tasks '\Microsoft\Windows\Server Manager\'
        Disable-Tasks '\Microsoft\Windows\Customer Experience Improvement Program\'
        Disable-Tasks '\Microsoft\Windows\Application Experience\'
        if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
            Set-MpPreference -ScanScheduleDay 8 -DisableCatchupFullScan $true -DisableCatchupQuickScan $true -ErrorAction SilentlyContinue
            'defender scheduled scans off'
        } else { 'defender not present' }
        Set-RegDword 'HKLM:\SOFTWARE\Microsoft\ServerManager' DoNotOpenServerManagerAtLogon 1
        # Automatic maintenance would otherwise run disk/component work on fresh clones.
        Set-RegDword 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' MaintenanceDisabled 1
    }
    Step 'time-power-pagefile' {
        Set-TimeZone -Id 'UTC'
        Set-RegDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' ClearPageFileAtShutdown 1
        & powercfg.exe /hibernate off
        "timezone $((Get-TimeZone).Id)"
    }
    Step 'smb-client-caches-off' {
        # Commands arrive through \\host.lan\Data\cmd; cached directory listings would delay each by up to 10 s.
        Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileInfoCacheLifetime 0 -FileNotFoundCacheLifetime 0 -Confirm:$false
        'directory/file info/file not found cache lifetimes 0'
    }
    Step 'dism-component-cleanup' {
        & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore /NoRestart | Select-String -Pattern 'Size|Recommended|Reclaimable'
        & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase /NoRestart | Select-Object -Last 4
        "dism exit $LASTEXITCODE"
    }
    Step 'purge-caches' {
        Remove-Contents @(
            'C:\ProgramData\National Instruments\NI Package Manager\packages',
            'C:\Windows\Temp', $env:TEMP,
            'C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
            'C:\Windows\SoftwareDistribution\Download', 'C:\Windows\Logs\CBS', 'C:\Windows\Logs\DISM',
            'C:\Windows\Minidump', 'C:\Windows\LiveKernelReports')
        Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Contents @("$($_.FullName)\AppData\Local\Temp")
        }
    }
    Save-Report 'rebooting'
    & shutdown.exe /r /t 20 /c 'sls image seal phase 1'
    exit 0
}

# ---------------------------------------------------------------- phase 2
Step 'stop-ni-services' {
    foreach ($s in 'NIWebServer', 'NI Skyline Service Manager', 'NI SystemLink Message Bus', 'NiSvcLoc', 'NINetworkDiscovery') {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { "$s missing"; continue }
        $t = Get-Date
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3)) } catch { }
        $svc.Refresh()
        '{0} {1} after {2:N1}s' -f $s, $svc.Status, ((Get-Date) - $t).TotalSeconds
    }
    # Module services (PostgreSQL, Salt master, asset/APM, ...): every other running service installed by NI.
    foreach ($w in @(Get-CimInstance Win32_Service -Filter "State='Running'" | Where-Object { $_.PathName -match '(?i)\\National Instruments\\' })) {
        $t = Get-Date
        Stop-Service -Name $w.Name -Force -ErrorAction SilentlyContinue
        $svc = Get-Service -Name $w.Name
        try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(3)) } catch { }
        $svc.Refresh()
        '{0} {1} after {2:N1}s' -f $w.Name, $svc.Status, ((Get-Date) - $t).TotalSeconds
    }
    $deadline = (Get-Date).AddSeconds(90)
    do {
        $left = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match '(?i)\\National Instruments\\' -or $_.Name -match '(?i)^(mongod|erl|beam\.smp|epmd|httpd|postgres|pg_ctl)\.exe$' })
        if ($left.Count -eq 0) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($left.Count) { 'leftover processes: ' + (($left | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ', ') } else { 'no NI processes left' }
}
Step 'verify-mongodb-shutdown' {
    $lock = 'C:\ProgramData\National Instruments\Skyline\NoSqlDatabase\db\mongod.lock'
    if (-not (Test-Path $lock)) { 'mongod.lock missing'; return }
    if ((Get-Item $lock).Length -eq 0) { 'mongod.lock empty (clean shutdown)'; return }
    # The NoSqlDatabase wrapper hard-kills mongod when it does not exit within its stop grace period, which happens
    # with the module services (hundreds of client connections closing at once, each logging a backtrace because NI's
    # mongodb.conf sets traceAllExceptions). mongod --repair replays the journal and exits with a clean shutdown.
    "mongod.lock not empty ($((Get-Item $lock).Length) bytes): mongod was not shut down cleanly; running mongod --repair"
    $mongod = 'C:\Program Files\National Instruments\Shared\Skyline\NoSqlDatabase\bin\mongod.exe'
    $log = Join-Path $env:TEMP 'mongod-repair.log'
    $t = Get-Date
    $p = Start-Process -FilePath $mongod -NoNewWindow -Wait -PassThru -ArgumentList @(
        '--dbpath', "`"$(Split-Path $lock)`"", '--repair', '--bind_ip', '127.0.0.1', '--port', '27099', '--logpath', "`"$log`"")
    'mongod --repair exit {0} after {1:N1}s' -f $p.ExitCode, ((Get-Date) - $t).TotalSeconds
    $len = (Get-Item $lock).Length
    if ($p.ExitCode -ne 0 -or $len -ne 0) {
        Get-Content $log -Tail 20 -ErrorAction SilentlyContinue
        throw "mongod --repair did not leave a clean shutdown (exit $($p.ExitCode), mongod.lock $len bytes)"
    }
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    'mongod.lock empty after repair (clean shutdown)'
}
if ($Steps | Where-Object { $_.name -eq 'verify-mongodb-shutdown' -and $_.error }) {
    Save-Report 'failed'
    exit 1
}
Step 'clear-ni-logs' {
    Remove-Contents @(
        'C:\ProgramData\National Instruments\Skyline\Logs',
        'C:\ProgramData\National Instruments\Skyline\NoSqlDatabase\log',
        'C:\ProgramData\National Instruments\Skyline\KeyValueDatabase\Logs',
        'C:\ProgramData\National Instruments\Skyline\RabbitMQ\log',
        'C:\Program Files\National Instruments\Shared\Skyline\Message\elixir\messageservices\bin\log',
        'C:\Program Files\National Instruments\Shared\Web Server\logs',
        'C:\ProgramData\National Instruments\Web Server\logs')
}
Step 'clear-event-logs' {
    $n = 0
    foreach ($l in (& wevtutil.exe el)) { & wevtutil.exe cl "$l" 2>$null; if ($LASTEXITCODE -eq 0) { $n++ } }
    "cleared $n logs"
}
Step 'clean-temp-and-agent' {
    Remove-Contents @('C:\Windows\Temp', $env:TEMP, 'C:\sls\cmd')
    foreach ($f in 'C:\sls\agent.log', 'C:\sls\bootstrap.log', 'C:\sls\webserver-setup.txt', 'C:\sls\webserver-setup.err.txt') {
        Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
    }
}
if (-not $NoRetrim) {
    Step 'retrim' {
        Optimize-Volume -DriveLetter C -ReTrim -Verbose 4>&1 | Select-Object -Last 3 | ForEach-Object { "$_" }
    }
}
Save-Report 'shutting-down'
& shutdown.exe /s /t 15 /c 'sls image seal phase 2'
exit 0
