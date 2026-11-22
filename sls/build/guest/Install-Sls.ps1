# SystemLink Server image build: unattended install inside the build VM (lean; no Phase 0 captures).
# Runs as SYSTEM from the SLS-Install startup task (Start-Install.ps1) and resumes across reboots via
# C:\sls-install\state.json. Reports to the host through \\host.lan\Data\install:
#   status.json (step states), install.log, logs\<exec>.txt, versions.json, packages.txt,
#   install.done = "completed" or "failed:<step>" (written last).
# Must stay compatible with Windows PowerShell 5.1 and ASCII-only.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\sls-install'
$Share = '\\host.lan\Data'
$Out = "$Share\install"
$Nipkg = Join-Path $env:ProgramFiles 'National Instruments\NI Package Manager\nipkg.exe'
$WsCmd = Join-Path $env:ProgramFiles 'National Instruments\Shared\Web Server Config\NIWebServerConfigurationCmd.exe'
$Cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json

$mutex = New-Object Threading.Mutex($false, 'Global\SLS-Install')
if (-not $mutex.WaitOne(0)) { exit 0 }
for ($i = 0; $i -lt 60 -and -not (Test-Path $Share); $i++) { Start-Sleep -Seconds 2 }
foreach ($d in $Root, "$Root\logs", "$Root\downloads", $Out, "$Out\logs") { New-Item -ItemType Directory -Force -Path $d -ErrorAction SilentlyContinue | Out-Null }

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    Add-Content -Path "$Root\install.log" -Value $line -Encoding ascii
    Add-Content -Path "$Out\install.log" -Value $line -Encoding ascii -ErrorAction SilentlyContinue
}

function Write-ShareFile([string]$Relative, [string]$Text) {
    $p = Join-Path $Out $Relative
    try {
        Set-Content -Path "$p.tmp" -Value $Text -Encoding ascii
        Move-Item -Path "$p.tmp" -Destination $p -Force
    } catch { Write-Log "WARN could not write $p : $($_.Exception.Message)" }
}

function Get-State {
    if (Test-Path "$Root\state.json") { return (Get-Content "$Root\state.json" -Raw | ConvertFrom-Json) }
    return [pscustomobject]@{ started = (Get-Date).ToUniversalTime().ToString('o'); boots = 0; reboots = 0; result = 'running'; current = $null; steps = [pscustomobject]@{} }
}

function Save-State($State) {
    $json = $State | ConvertTo-Json -Depth 6
    Set-Content -Path "$Root\state.json" -Value $json -Encoding ascii
    Write-ShareFile 'status.json' $json
}

function Get-Step($State, [string]$Id) {
    $p = $State.steps.PSObject.Properties[$Id]
    if ($p) { return $p.Value }
    $v = [pscustomobject]@{ status = 'pending'; attempts = 0; sec = $null; error = $null }
    $State.steps | Add-Member -NotePropertyName $Id -NotePropertyValue $v
    return $v
}

function Invoke-Exe {
    # Runs an executable with a timeout; stdout+stderr go to logs\<Name>.txt (local and share). $Display is logged
    # instead of the real arguments (secrets).
    param([string]$FilePath, [string]$Arguments, [string]$Name, [int]$TimeoutSec = 3600, [string]$Display = $null)
    if ($null -eq $Display) { $Display = $Arguments }
    $log = "$Root\logs\$Name.txt"
    $errLog = "$Root\logs\$Name.err.txt"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -RedirectStandardOutput $log -RedirectStandardError $errLog `
        -NoNewWindow -PassThru -WorkingDirectory $env:TEMP
    $null = $p.Handle
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; $p.WaitForExit(10000) | Out-Null }
    $code = $null
    try { $code = $p.ExitCode } catch { }
    $text = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + (Get-Content $errLog -Raw -ErrorAction SilentlyContinue)
    Set-Content -Path "$Out\logs\$Name.txt" -Value "> $FilePath $Display`r`n$text" -Encoding ascii -ErrorAction SilentlyContinue
    Write-Log ('exec {0} exit={1} timedOut={2} {3:N1}s' -f $Name, $code, $timedOut, $sw.Elapsed.TotalSeconds)
    return [pscustomobject]@{ ExitCode = $code; TimedOut = $timedOut; Text = $text }
}

function Invoke-Nipkg([string]$Arguments, [string]$Name, [int]$TimeoutSec = 3600) {
    if (-not (Test-Path $Nipkg)) { throw "nipkg.exe not found at $Nipkg" }
    return Invoke-Exe -FilePath $Nipkg -Arguments $Arguments -Name $Name -TimeoutSec $TimeoutSec
}

function Get-InstalledPackages {
    $r = Invoke-Nipkg 'list-installed' 'nipkg-list-installed' 600
    $pk = [ordered]@{}
    foreach ($line in ($r.Text -split "`r?`n")) { if ($line -match '^\s*(ni-\S+|eula-\S+)\s+(\S+)') { $pk[$matches[1]] = $matches[2] } }
    Set-Content -Path "$Out\packages.txt" -Value $r.Text -Encoding ascii -ErrorAction SilentlyContinue
    return $pk
}

function Test-PendingReboot {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { if (Test-Path $k) { return $true } }
    $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    return [bool]($sm -and $sm.PendingFileRenameOperations)
}

function Get-HttpStatus([string]$Url, [string]$User = '', [string]$Password = '') {
    try {
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 10000
        $req.AllowAutoRedirect = $false
        if ($User) { $req.Headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:$Password")) }
        $resp = $req.GetResponse(); $c = [int]$resp.StatusCode; $resp.Close(); return $c
    } catch {
        $e = $_.Exception.GetBaseException()
        if ($e -is [Net.WebException] -and $e.Response) { $c = [int]$e.Response.StatusCode; $e.Response.Close(); return $c }
        return 0
    }
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSec, [int]$IntervalSec = 5) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do { if (& $Condition) { return $true }; Start-Sleep -Seconds $IntervalSec } while ((Get-Date) -lt $deadline)
    return $false
}

function Save-PasswordMarker([string]$Password) {
    # Same format as Agent.ps1: lets the runtime agent skip the web server setup when SLS_ADMIN_PASSWORD equals the
    # current password. Salted PBKDF2, never the password itself.
    $salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, 20000)
    $o = [ordered]@{ salt = [Convert]::ToBase64String($salt); hash = [Convert]::ToBase64String($kdf.GetBytes(32)); iterations = 20000
        setUtc = (Get-Date).ToUniversalTime().ToString('o'); by = 'image-build' }
    New-Item -ItemType Directory -Force -Path 'C:\sls' | Out-Null
    Set-Content -Path 'C:\sls\admin-password.json' -Value ($o | ConvertTo-Json) -Encoding ascii
}

# ---------------------------------------------------------------- steps
$Steps = @(
    @{ Id = 'init'; Action = {
        $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        Write-Log "windows $($os.ProductName) $($os.EditionID) build $($os.CurrentBuild).$($os.UBR) computer=$env:COMPUTERNAME"
        $ok = Wait-Until { try { $null = Resolve-DnsName download.ni.com -ErrorAction Stop; $true } catch { $false } } 300 5
        if (-not $ok) { throw 'download.ni.com does not resolve (no network?)' }
    } },
    @{ Id = 'defender-realtime-off'; Action = {
        # Real-time scanning of the NI install and of every container start costs minutes; the image is a test server.
        if (Get-Command Set-MpPreference -ErrorAction SilentlyContinue) {
            try { Set-MpPreference -DisableRealtimeMonitoring $true; Write-Log 'defender real-time monitoring disabled' }
            catch { Write-Log "defender change failed: $($_.Exception.Message)" }
        } else { Write-Log 'defender not present' }
    } },
    @{ Id = 'install-nipm'; Action = {
        $installer = "$Root\downloads\nipm-installer.exe"
        Write-Log "downloading $($Cfg.nipmUrl)"
        Invoke-WebRequest -Uri $Cfg.nipmUrl -OutFile $installer -UseBasicParsing
        $r = Invoke-Exe -FilePath $installer -Arguments $Cfg.nipmInstallArgs -Name 'nipm-install' -TimeoutSec 3600
        if (-not (Test-Path $Nipkg)) { throw "NIPM install did not produce nipkg.exe (exit $($r.ExitCode))" }
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        if (Test-PendingReboot) { return 'reboot' }
    } },
    @{ Id = 'add-feeds'; Action = {
        $i = 0
        foreach ($f in $Cfg.feeds) {
            $i++
            # Non-zero when the feed already exists (resumed step); "nipkg update" below is the real check.
            $null = Invoke-Nipkg "feed-add $f" "nipkg-feed-add-$i" 300
        }
        $u = Invoke-Nipkg 'update' 'nipkg-update' 1800
        if ($u.ExitCode -ne 0) { throw "nipkg update failed ($($u.ExitCode))" }
        $null = Invoke-Nipkg 'feed-list' 'nipkg-feed-list' 300
    } },
    @{ Id = 'install-sls'; Action = {
        $a = 'install {0} {1}' -f ($Cfg.packages -join ' '), $Cfg.installFlags
        $r = Invoke-Nipkg $a 'nipkg-install' ([int]$Cfg.installTimeoutMinutes * 60)
        if ($r.TimedOut) { throw 'nipkg install timed out' }
        $installed = Get-InstalledPackages
        $missing = @($Cfg.packages | Where-Object { -not $installed.Contains($_) })
        if ($missing.Count) { throw "packages not installed: $($missing -join ', ') (exit $($r.ExitCode))" }
        if ($r.ExitCode -ne 0) { Write-Log "nipkg install exit $($r.ExitCode) but all packages are installed" }
        if (Test-PendingReboot) { return 'reboot' }
    } },
    @{ Id = 'reboot'; Action = {
        # One clean boot with all NI services installed before configuring the web server (as in Phase 0).
        'reboot'
    } },
    @{ Id = 'configure-webserver'; Action = {
        if (-not (Test-Path $WsCmd)) { throw "not found: $WsCmd" }
        # NIWebServer ships Disabled until configured. insecure-remote = HTTP on port 80, managed authentication with
        # the "admin" account (TLS, if needed, is terminated in front of the container).
        $template = [string]$Cfg.webServerSetupArgs
        $r = Invoke-Exe -FilePath $WsCmd -Arguments $template.Replace('{adminPassword}', [string]$Cfg.adminPassword) `
            -Display $template -Name 'webserver-setup' -TimeoutSec 600
        if ($r.ExitCode -ne 0) { throw "web server setup failed ($($r.ExitCode))" }
        if (-not (Wait-Until { (Get-HttpStatus 'http://localhost/niauth/v1/user') -in 200, 401 } 600 5)) { throw 'web server not answering on http://localhost' }
        $authOk = Wait-Until { (Get-HttpStatus 'http://localhost/niauth/v1/user' $Cfg.adminUser $Cfg.adminPassword) -eq 200 } 600 5
        if (-not $authOk) { throw "admin login on http://localhost failed (last $(Get-HttpStatus 'http://localhost/niauth/v1/user' $Cfg.adminUser $Cfg.adminPassword))" }
        Save-PasswordMarker ([string]$Cfg.adminPassword)
        Write-Log 'web server answering; admin login works'
    } },
    @{ Id = 'record-versions'; Action = {
        $pk = Get-InstalledPackages
        $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $eval = $null
        try {
            $p = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" | Select-Object -First 1
            $eval = [ordered]@{ name = $p.Name; licenseStatus = $p.LicenseStatus; graceMinutesRemaining = $p.GracePeriodRemaining
                expiresUtc = (Get-Date).ToUniversalTime().AddMinutes([double]$p.GracePeriodRemaining).ToString('o') }
        } catch { $eval = [ordered]@{ error = $_.Exception.Message } }
        $products = [ordered]@{}
        foreach ($p in $Cfg.packages) { $products[$p] = $pk[$p] }
        $v = [ordered]@{
            systemlinkServer = $pk['ni-systemlink-server']; nipm = $pk['ni-package-manager']; products = $products
            packages = $Cfg.packages; feeds = $Cfg.feeds; installedPackageCount = $pk.Count
            windows = [ordered]@{ productName = $os.ProductName; editionId = $os.EditionID; build = "$($os.CurrentBuild).$($os.UBR)"; displayVersion = $os.DisplayVersion }
            eval = $eval
        }
        Write-ShareFile 'versions.json' ($v | ConvertTo-Json -Depth 4)
        Write-Log "versions: systemlink=$($v.systemlinkServer) nipm=$($v.nipm) windows=$($v.windows.build) products=$(($products.Keys | ForEach-Object { "$_=$($products[$_])" }) -join ',')"
    } },
    @{ Id = 'install-agent'; Action = {
        # The bootstrap stays on the disk; the agent itself is mirrored from the image's guest folder on every boot.
        $src = "$Share\guest\Bootstrap.ps1"
        if (-not (Test-Path $src)) { throw "missing $src (the host stages image/guest into the shared folder)" }
        New-Item -ItemType Directory -Force -Path 'C:\sls' | Out-Null
        Copy-Item $src 'C:\sls\Bootstrap.ps1' -Force
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\sls\Bootstrap.ps1"'
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName 'SLS-Agent' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName 'SLS-Agent'
        Write-Log 'agent task registered and started'
    } }
)

# ---------------------------------------------------------------- runner
$State = Get-State
$State.boots++
Save-State $State
Write-Log "runner start boot=$($State.boots) result=$($State.result)"
if ($State.result -ne 'running') { $mutex.ReleaseMutex(); exit 0 }

$failed = $null
foreach ($s in $Steps) {
    $st = Get-Step $State $s.Id
    if ($st.status -eq 'done') { continue }
    if ($st.status -eq 'rebooting') { $st.status = 'done'; Save-State $State; continue }
    if ($st.attempts -ge 2) { $st.status = 'failed'; $st.error = 'interrupted twice (unexpected reboot or crash)'; $failed = $s.Id; break }
    $State.current = $s.Id
    $st.status = 'running'; $st.attempts++
    Save-State $State
    Write-Log "step start: $($s.Id)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $result = & $s.Action | Select-Object -Last 1
        $st.sec = [math]::Round($sw.Elapsed.TotalSeconds)
        if ($result -eq 'reboot' -and $State.reboots -lt [int]$Cfg.maxReboots) {
            $st.status = 'rebooting'; $State.reboots++
            Save-State $State
            Write-Log "step $($s.Id) done ($($st.sec)s), rebooting"
            Restart-Computer -Force
            exit 0
        }
        $st.status = 'done'
        Write-Log "step done: $($s.Id) ($($st.sec)s)"
    } catch {
        $st.sec = [math]::Round($sw.Elapsed.TotalSeconds)
        $st.status = 'failed'; $st.error = $_.Exception.Message
        Write-Log "step FAILED: $($s.Id): $($_.Exception.Message)"
        $failed = $s.Id
        Save-State $State
        break
    }
    Save-State $State
}
$State.current = $null
$State.result = if ($failed) { 'failed' } else { 'completed' }
$State | Add-Member -NotePropertyName finished -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
Save-State $State
if (-not $failed) { Disable-ScheduledTask -TaskName 'SLS-Install' -ErrorAction SilentlyContinue | Out-Null }
Write-Log "install $($State.result)"
Write-ShareFile 'install.done' $(if ($failed) { "failed:$failed" } else { 'completed' })
$mutex.ReleaseMutex()
