# Collects SystemLink Server and Windows diagnostics into \\host.lan\Data\logs\<Name> (= /shared/logs/<Name> in the
# container). Run through the agent command channel by the sls-logs container command; progress goes to stdout.
# Must stay compatible with Windows PowerShell 5.1 and ASCII-only.
param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$Name, [int]$EventCount = 500, [int]$MaxFileMB = 100)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Dest = "\\host.lan\Data\logs\$Name"
$Local = "C:\Windows\Temp\sls-logs-$Name"
foreach ($d in $Dest, $Local) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$sw = [Diagnostics.Stopwatch]::StartNew()
function Note([string]$m) { Write-Output ('[{0,5:N0}s] {1}' -f $sw.Elapsed.TotalSeconds, $m) }

# Same folders as the seal's clear-ni-logs step.
$NiLogs = [ordered]@{
    'skyline'           = 'C:\ProgramData\National Instruments\Skyline\Logs'
    'mongodb'           = 'C:\ProgramData\National Instruments\Skyline\NoSqlDatabase\log'
    'keyvalue-db'       = 'C:\ProgramData\National Instruments\Skyline\KeyValueDatabase\Logs'
    'rabbitmq'          = 'C:\ProgramData\National Instruments\Skyline\RabbitMQ\log'
    'message-services'  = 'C:\Program Files\National Instruments\Shared\Skyline\Message\elixir\messageservices\bin\log'
    'web-server'        = 'C:\Program Files\National Instruments\Shared\Web Server\logs'
    'web-server-data'   = 'C:\ProgramData\National Instruments\Web Server\logs'
}
foreach ($k in $NiLogs.Keys) {
    $src = $NiLogs[$k]
    if (-not (Test-Path $src)) { Note "skip $k (missing)"; continue }
    # /MAX skips huge files (database dumps); open log files are copied in backup mode where possible.
    $null = & robocopy.exe $src "$Dest\ni\$k" /E /R:1 /W:1 /MAX:$($MaxFileMB * 1MB) /NP /NFL /NDL /NJH /NJS /XJ
    Note "ni/$k (robocopy $LASTEXITCODE)"
}

foreach ($log in 'Application', 'System') {
    & wevtutil.exe epl $log "$Local\$log.evtx" /ow:true 2>&1 | Out-Null
    Copy-Item "$Local\$log.evtx" "$Dest\windows-$log.evtx" -ErrorAction SilentlyContinue
    Get-WinEvent -LogName $log -MaxEvents $EventCount -ErrorAction SilentlyContinue |
        ForEach-Object { '{0:u} {1,-11} {2} [{3}] {4}' -f $_.TimeCreated.ToUniversalTime(), $_.LevelDisplayName, $_.ProviderName, $_.Id, ($_.Message -replace '\s+', ' ') } |
        Set-Content -Path "$Dest\windows-$log.txt" -Encoding ascii
    Note "windows $log events"
}

Get-CimInstance Win32_Service | Where-Object { $_.DisplayName -match '(?i)^NI |National Instruments|SystemLink' -or $_.Name -match '(?i)^NI' } |
    Sort-Object Name | Select-Object Name, DisplayName, State, StartMode, ProcessId, PathName |
    Export-Csv -Path "$Dest\ni-services.csv" -NoTypeInformation -Encoding ascii
Note 'ni services'

$nipkg = Join-Path $env:ProgramFiles 'National Instruments\NI Package Manager\nipkg.exe'
if (Test-Path $nipkg) { & $nipkg list-installed 2>&1 | Set-Content -Path "$Dest\nipkg-installed.txt" -Encoding ascii; Note 'nipkg list-installed' }

$sys = [ordered]@{
    utc = (Get-Date).ToUniversalTime().ToString('o')
    lastBootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object { [ordered]@{ drive = $_.DeviceID; sizeGB = [math]::Round($_.Size / 1GB, 1); freeGB = [math]::Round($_.FreeSpace / 1GB, 1) } }
    memory = Get-CimInstance Win32_OperatingSystem | ForEach-Object { [ordered]@{ totalMB = [math]::Round($_.TotalVisibleMemorySize / 1KB); freeMB = [math]::Round($_.FreePhysicalMemory / 1KB) } }
    topProcesses = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 25 | ForEach-Object { [ordered]@{ name = $_.Name; id = $_.Id; workingSetMB = [math]::Round($_.WorkingSet64 / 1MB); cpuSec = [math]::Round($_.CPU, 1) } }
}
Set-Content -Path "$Dest\system.json" -Value ($sys | ConvertTo-Json -Depth 4) -Encoding ascii
Note 'system summary'

foreach ($f in 'C:\sls\agent.log', 'C:\sls\bootstrap.log', 'C:\sls\webserver-setup.txt', 'C:\sls\webserver-setup.err.txt') {
    if (Test-Path $f) { Copy-Item $f "$Dest\guest-$(Split-Path $f -Leaf)" -ErrorAction SilentlyContinue }
}
Remove-Item -Path $Local -Recurse -Force -ErrorAction SilentlyContinue
$bytes = (Get-ChildItem -Path $Dest -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Note ('done: {0:N1} MB in {1}' -f ($bytes / 1MB), $Dest)
