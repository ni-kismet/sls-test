#Requires -Version 7.2
<#
.SYNOPSIS
Example integration test against a SystemLink Server container: start, wait healthy, assert through the API (polling,
not sleeping), run a command in the guest, save logs on failure, remove the container.

.EXAMPLE
$env:SLS_IMAGE = 'sls-server:26.5-demo'; $env:SLS_TEST_PASSWORD = '<image admin password>'
pwsh testkit/examples/Test-SlsServer.ps1
.EXAMPLE
pwsh testkit/examples/Test-SlsServer.ps1 -Image sls-server:26.5-demo -AdminPassword (Read-Host -AsSecureString)
#>
param(
    [string]$Image = $(if ($env:SLS_IMAGE) { $env:SLS_IMAGE } else { 'sls-server:26.5-demo' }),
    # The image's admin password (SLS_TEST_PASSWORD) or, with -SetPassword, the password to set at start.
    [securestring]$AdminPassword = $(if ($env:SLS_TEST_PASSWORD) { ConvertTo-SecureString $env:SLS_TEST_PASSWORD -AsPlainText -Force }),
    [switch]$SetPassword,
    [string]$LogDir = (Join-Path ([IO.Path]::GetTempPath()) 'sls-test-logs')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\SlsTestKit.psm1') -Force
if (-not $AdminPassword) { throw 'set SLS_TEST_PASSWORD or pass -AdminPassword' }
$cred = [pscredential]::new('admin', $AdminPassword)

$failures = [Collections.Generic.List[string]]::new()
function Assert([string]$Name, [scriptblock]$Test) {
    try { & $Test; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $failures.Add($Name); Write-Host "FAIL $Name`n     $($_.Exception.Message)" -ForegroundColor Red }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$server = if ($SetPassword) { Start-SlsServer -Image $Image -AdminCredential $cred } else { Start-SlsServer -Image $Image -Credential $cred }
Write-Host "started $($server.Name) ($Image) at $($server.BaseUrl), healthy after $([math]::Round($sw.Elapsed.TotalSeconds)) s"
try {
    Assert 'authenticated API call' {
        $u = Invoke-SlsApi $server 'niauth/v1/auth'
        if (-not $u) { throw 'no response' }
    }
    Assert 'anonymous call is rejected' {
        $r = Invoke-SlsApi $server 'nitag/v2/tags?take=1' -Anonymous -PassThru
        if ($r.Status -ne 401) { throw "expected 401, got $($r.Status)" }
    }
    Assert 'tag write/read' {
        Invoke-SlsApi $server 'nitag/v2/tags/test.example.value' -Method PUT -Body @{ type = 'DOUBLE'; path = 'test.example.value' } | Out-Null
        Invoke-SlsApi $server 'nitag/v2/tags/test.example.value/values/current' -Method PUT -Body @{ value = @{ type = 'DOUBLE'; value = '3.5' } } | Out-Null
        Wait-SlsCondition { (Invoke-SlsApi $server 'nitag/v2/tags/test.example.value/values/current').value.value -eq '3.5' } -TimeoutSec 60 -Message 'tag value' | Out-Null
    }
    if ("$(& docker image inspect -f '{{ index .Config.Labels "com.ni.sls.config" }}' $Image)".Trim() -eq 'demo') {
        Assert 'demo configuration data is preloaded' {
            Wait-SlsCondition { (Invoke-SlsApi $server 'nitag/v2/tags/demo.line1.sensor001/values/current').value.value -eq '1.25' } -TimeoutSec 60 -Message 'demo tag' | Out-Null
        }
    }
    Assert 'guest command (sls-exec)' {
        $r = Invoke-SlsGuest $server "(Get-Service -Name 'NI*' | Where-Object Status -eq Running).Count"
        if ([int]($r.Output | Select-Object -Last 1) -lt 5) { throw "few NI services running: $($r.Output -join ' ')" }
    }
} finally {
    if ($failures.Count) {
        $files = Save-SlsLogs $server -Path $LogDir
        Write-Host "logs: $($files -join ', ')"
    }
    Stop-SlsServer $server
}
if ($failures.Count) { Write-Host "$($failures.Count) failed: $($failures -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host "all passed in $([math]::Round($sw.Elapsed.TotalSeconds)) s"
