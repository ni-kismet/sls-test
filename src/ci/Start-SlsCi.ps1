#Requires -Version 7.2
<#
.SYNOPSIS
Starts a SystemLink Server container for CI (body of the sls-start-server action) and waits until it is usable.

.DESCRIPTION
Pulls -Image when it is not present locally (with retries), removes an existing container of the same name when
-Replace (fails otherwise), starts it with the testkit's Start-SlsServer and waits. The web admin password is
SLS_ADMIN_PASSWORD, else 'test'; it is set at start (about 40 s) unless the image's com.ni.sls.admin-password label says
it already has it. Waits for:
  healthy   container healthcheck (guest agent ready, runtime settings applied, API answering)
  services  healthy plus one read-only call per migration resource answering (Test-SlsServiceCoverage, waits up to
            -ServicesTimeoutSec for services still starting)
  none      returns after docker run
A Windows bugcheck or an exited container while starting is retried up to -CrashRetries times with a new container
(the failed container's logs go below -LogDir); other failures (timeout, runtime settings failure) are not retried.

GitHub step outputs: base-url, container, http-port, pull-sec, healthy-sec, ready-sec, attempts, bugchecks, crash (the
last bugcheck's stop code), log-dir. Exported to later steps (GITHUB_ENV): SLS_BASE_URL, SLS_CONTAINER, SLS_HTTP_PORT.

.EXAMPLE
pwsh src/ci/Start-SlsCi.ps1 -Image ghcr.io/rajsite/sls-server:26.5-migration -Name sls
#>
param(
    [Parameter(Mandatory)][string]$Image,
    [string]$Name = 'sls',
    [bool]$Replace = $false,
    [string]$Ram = '8G',
    [int]$Cpu = 4,
    [int]$HttpPort = 0,
    [ValidateSet('healthy', 'services', 'none')][string]$WaitFor = 'services',
    [int]$TimeoutSec = 900,
    [int]$ServicesTimeoutSec = 600,
    [int]$CrashRetries = 1,
    [string]$Volume = '',
    [string]$LicenseUser = $env:SLS_LICENSE_USER,
    # Comma separated license files (mounted read-only, placed in the guest before ready).
    [string]$LicenseFile = '',
    [string]$LogDir = $(Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }) 'sls-start-logs')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'testkit/SlsTestKit.psm1') -Force

function Write-CiOutput([Collections.IDictionary]$Values) {
    if (-not $env:GITHUB_OUTPUT) { return }
    foreach ($k in $Values.Keys) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$k=$($Values[$k])" -Encoding utf8 }
}
function Add-Summary([string[]]$Lines) {
    if ($env:GITHUB_STEP_SUMMARY) { $Lines -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 } else { $Lines | Write-Host }
}

$password = if ($env:SLS_ADMIN_PASSWORD) { $env:SLS_ADMIN_PASSWORD } else { 'test' }
$cred = [pscredential]::new('admin', (ConvertTo-SecureString $password -AsPlainText -Force))
$licenses = @($LicenseFile -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$sw = [Diagnostics.Stopwatch]::StartNew()
& docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
    for ($i = 1; ; $i++) {
        & docker pull $Image
        if ($LASTEXITCODE -eq 0) { break }
        if ($i -ge 3) { throw "docker pull $Image failed 3 times" }
        Start-Sleep -Seconds (30 * $i)
    }
} else { Write-Host "using local image $Image" }
$pullSec = [math]::Round($sw.Elapsed.TotalSeconds)
# Only the non-secret default is ever in the label; anything else is 'custom' (or missing on older images).
$imagePassword = "$(& docker image inspect -f '{{index .Config.Labels "com.ni.sls.admin-password"}}' $Image 2>$null)".Trim()
$credArgs = if ($imagePassword -and $imagePassword -ceq $password) { @{ Credential = $cred } } else { @{ AdminCredential = $cred } }
Write-Host "web admin password: $(if ($credArgs.Credential) { 'already set in the image' } else { 'set at start' })"

if ("$(& docker inspect -f '{{.Name}}' $Name 2>$null)".Trim()) {
    if (-not $Replace) { throw "a container named $Name exists; pass replace: true to remove it" }
    Write-Host "removing existing container $Name"
    Stop-SlsServer $Name
}

$attempts = 0; $bugchecks = 0; $server = $null; $healthySec = $null; $crashCode = ''
for ($n = 1; $n -le $CrashRetries + 1; $n++) {
    $attempts = $n
    $sw.Restart()
    try {
        $server = Start-SlsServer -Image $Image -Name $Name @credArgs -Ram $Ram -Cpu $Cpu -HttpPort $HttpPort `
            -Volume $Volume -LicenseUser $LicenseUser -LicenseFile $licenses -TimeoutSec $TimeoutSec -NoWait:($WaitFor -eq 'none')
        $healthySec = if ($WaitFor -eq 'none') { $null } else { [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        break
    } catch {
        $msg = $_.Exception.Message
        $crash = $msg -match 'bugcheck|is exited|is gone|is dead'
        if ($msg -match 'bugcheck') { $bugchecks++; if ($msg -match 'bugcheck in \S+ \(([^)]*)\)') { $crashCode = $matches[1] } }
        Write-Host "::warning::start attempt $n of $($CrashRetries + 1) failed: $(($msg -split "`n")[0])"
        $dir = Join-Path $LogDir "$Name-a$n"
        try { Save-SlsLogs $Name -Path $dir -TimeoutSec 120 | Out-Null } catch { Write-Host "log collection failed: $($_.Exception.Message)" }
        if (-not $crash -or $n -gt $CrashRetries) {
            Write-CiOutput ([ordered]@{ container = $Name; 'pull-sec' = $pullSec; attempts = $attempts; bugchecks = $bugchecks; crash = $crashCode; 'log-dir' = $LogDir })
            Add-Summary @("SystemLink Server ``$Image`` failed to start after $attempts attempt(s) ($bugchecks bugcheck(s)): $(($msg -split "`n")[0])")
            throw
        }
        Stop-SlsServer $Name
    }
}

$readySec = $healthySec
$coverage = @()
if ($WaitFor -eq 'services') {
    $coverage = Test-SlsServiceCoverage $server -WaitSec $ServicesTimeoutSec -Throw
    $readySec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}

if ($env:GITHUB_ENV) {
    Add-Content $env:GITHUB_ENV -Value "SLS_BASE_URL=$($server.BaseUrl)", "SLS_CONTAINER=$Name", "SLS_HTTP_PORT=$($server.HttpPort)" -Encoding utf8
}
Write-CiOutput ([ordered]@{ 'base-url' = $server.BaseUrl; container = $Name; 'http-port' = $server.HttpPort; 'pull-sec' = $pullSec
        'healthy-sec' = $healthySec; 'ready-sec' = $readySec; attempts = $attempts; bugchecks = $bugchecks; crash = $crashCode; 'log-dir' = $LogDir })
$cov = if ($coverage) { ' services: ' + (($coverage | ForEach-Object { "$($_.Resource) $($_.Result)" }) -join ', ') } else { '' }
Add-Summary @("SystemLink Server ``$Image`` as ``$Name`` at $($server.BaseUrl): pull $pullSec s, healthy $healthySec s, ready ($WaitFor) $readySec s, $attempts attempt(s), $bugchecks bugcheck(s).$cov")
Write-Host "SystemLink Server $Name ready at $($server.BaseUrl)"
