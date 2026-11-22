# Registers Install-Sls.ps1 as the SLS-Install SYSTEM startup task (resumes after reboots) and starts it.
# Must stay compatible with Windows PowerShell 5.1 and ASCII-only.
$ErrorActionPreference = 'Stop'
$taskName = 'SLS-Install'
$runner = Join-Path $PSScriptRoot 'Install-Sls.ps1'

Write-Output "$(Get-Date -Format o) registering scheduled task $taskName -> $runner"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runner`""
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output "$(Get-Date -Format o) started $taskName"
