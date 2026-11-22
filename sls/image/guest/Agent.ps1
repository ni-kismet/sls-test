# SystemLink Server container guest agent. Runs as SYSTEM; started at boot by C:\sls\Bootstrap.ps1 (task SLS-Agent)
# from C:\sls\guest, which mirrors \\host.lan\Data\guest (= the image's /opt/sls/guest).
#   agent\boot.json     boot facts
#   runtime\config.json runtime settings written by start.sh (admin password, license user; deleted after reading)
#   runtime\licenses\   license files copied by start.sh from /licenses
#   agent\runtime.json  what was applied (no secrets): status pending | none | applied | failed
#   agent\ready.json    written once the NI services, HTTP and the requested settings work (the healthcheck needs it)
#   cmd\<id>.ps1        command channel: runs as SYSTEM, output streamed to cmd-out\<id>.out, exit code in <id>.exit;
#                       cmd\<id>.cancel kills it. Commands run concurrently and never block readiness.
#   agent\agent.log     shown in "docker logs" by start.sh
# Must stay compatible with Windows PowerShell 5.1 and ASCII-only.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Share = '\\host.lan\Data'
$Root = 'C:\sls'
$GuestDir = "$Root\guest"
$ReadyServices = @('NI Skyline Service Manager', 'NI SystemLink Message Bus', 'NIWebServer')
# Every other automatic NI service (module services such as PostgreSQL, Salt, asset/APM) is also waited for, but at
# most $AutoServicesGraceSec after the core services run: a service that stops by design must not block readiness.
$AutoServices = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto'" -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match '(?i)\\National Instruments\\' -and $_.Name -notin $ReadyServices } | ForEach-Object { $_.Name } | Sort-Object)
$AutoServicesGraceSec = 180
$WsCmd = Join-Path $env:ProgramFiles 'National Instruments\Shared\Web Server Config\NIWebServerConfigurationCmd.exe'
$WsSetupArgs = 'setup insecure-remote --admin-pass pass:{0} --yes --port 80 --finish --no-interactive'
$AdminUser = 'admin'
$LicenseDir = Join-Path $env:ProgramData 'National Instruments\License Manager\Licenses'
# Run-time license files and users the agent added; Seal-Vm.ps1 removes them so they never end up in an image layer.
$PlacedList = 'C:\sls\runtime-placed.txt'
$MarkerFile = "$Root\admin-password.json"

$mutex = New-Object Threading.Mutex($false, 'Global\SLS-Agent')
if (-not $mutex.WaitOne(0)) { exit 0 }

foreach ($d in $Root, "$Root\cmd") { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$AgentStart = Get-Date
$AgentUptime = [math]::Round(([Environment]::TickCount -band 0x7FFFFFFF) / 1000.0, 1)
# Unique per agent start (= per boot). LastBootUpTime shifts when the clock is corrected after boot.
$BootId = [guid]::NewGuid().ToString()

function Get-Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
# Uptime-based: the wall clock can jump right after boot (time zone / RTC correction).
function Get-UptimeSec { [math]::Round(([Environment]::TickCount -band 0x7FFFFFFF) / 1000.0, 1) }

function Write-AgentLog([string]$Message) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    Add-Content -Path "$Root\agent.log" -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    if (Test-Path $Share) {
        New-Item -ItemType Directory -Force -Path "$Share\agent" -ErrorAction SilentlyContinue | Out-Null
        Add-Content -Path "$Share\agent\agent.log" -Value $line -Encoding ascii -ErrorAction SilentlyContinue
    }
}

function Write-ShareFile([string]$Relative, [string]$Text) {
    $p = Join-Path $Share $Relative
    New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path "$p.tmp" -Value $Text -Encoding ascii
    Move-Item -Path "$p.tmp" -Destination $p -Force
}

function Get-HttpStatus([string]$Path = 'niauth/v1/user', [string]$User = '', [string]$Password = '') {
    try {
        $req = [Net.HttpWebRequest]::Create("http://localhost/$Path")
        $req.Timeout = 5000
        $req.AllowAutoRedirect = $false
        if ($User) { $req.Headers['Authorization'] = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:$Password")) }
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return $code
    } catch {
        # PowerShell wraps the WebException; a 401 still carries a response.
        $e = $_.Exception.GetBaseException()
        if ($e -is [Net.WebException] -and $e.Response) { $c = [int]$e.Response.StatusCode; $e.Response.Close(); return $c }
        return 0
    }
}

function Get-ServiceStates {
    $o = [ordered]@{}
    foreach ($n in @($ReadyServices) + @($AutoServices)) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        $o[$n] = if ($s) { "$($s.Status)" } else { 'missing' }
    }
    return $o
}

function Get-EvalInfo {
    try {
        $p = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1
        return [ordered]@{ name = $p.Name; licenseStatus = $p.LicenseStatus; graceMinutesRemaining = $p.GracePeriodRemaining }
    } catch { return [ordered]@{ error = $_.Exception.Message } }
}

function Get-PasswordHash([string]$Password, [byte[]]$Salt, [int]$Iterations) {
    $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations)
    return [Convert]::ToBase64String($kdf.GetBytes(32))
}

function Test-PasswordMarker([string]$Password) {
    # True when $Password is the admin password last set by the image build or this agent (salted PBKDF2 marker).
    if (-not (Test-Path $MarkerFile)) { return $false }
    try {
        $m = Get-Content $MarkerFile -Raw | ConvertFrom-Json
        return (Get-PasswordHash $Password ([Convert]::FromBase64String($m.salt)) ([int]$m.iterations)) -eq $m.hash
    } catch { return $false }
}

function Save-PasswordMarker([string]$Password) {
    $salt = New-Object byte[] 16
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $o = [ordered]@{ salt = [Convert]::ToBase64String($salt); hash = Get-PasswordHash $Password $salt 20000; iterations = 20000
        setUtc = Get-Iso (Get-Date); by = 'agent' }
    Set-Content -Path $MarkerFile -Value ($o | ConvertTo-Json) -Encoding ascii
}

function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return 'Sls-' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })) + '!9a'
}

# ---------------------------------------------------------------- command channel
$Running = @{}
# First failed start per command id: a file just renamed into cmd\ can be briefly unopenable over SMB; retry for 15 s.
$StartFailures = @{}

function Copy-NewBytes([string]$Source, [string]$Destination, [long]$Offset) {
    # Appends what $Source gained since $Offset to $Destination (the source is still being written).
    try {
        $fs = [IO.File]::Open($Source, 'Open', 'Read', 'ReadWrite')
        try {
            $len = [Math]::Min($fs.Length - $Offset, 4MB)
            if ($len -le 0) { return $Offset }
            $null = $fs.Seek($Offset, 'Begin')
            $buf = New-Object byte[] $len
            $n = $fs.Read($buf, 0, $len)
        } finally { $fs.Close() }
        $d = [IO.File]::Open($Destination, 'Append', 'Write', 'ReadWrite')
        try { $d.Write($buf, 0, $n) } finally { $d.Close() }
        return $Offset + $n
    } catch { return $Offset }
}

function Start-QueuedCommands {
    $dir = "$Share\cmd"
    if (-not (Test-Path $dir)) { return }
    $queued = @(Get-ChildItem -Path $dir -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name | Where-Object { $_.Extension -eq '.ps1' -and -not $Running.ContainsKey($_.BaseName) })
    if (-not $queued) { return }
    # Commands may call scripts from C:\sls\guest; pick up a newer image's copy.
    $null = & robocopy.exe "$Share\guest" $GuestDir /MIR /R:2 /W:1 /NP /NFL /NDL /NJH /NJS
    foreach ($f in $queued) {
        $id = $f.BaseName
        $local = "$Root\cmd\$id.ps1"
        $out = "$Root\cmd\$id.out"
        $shareOut = "$Share\cmd-out\$id.out"
        try {
            Copy-Item -Path $f.FullName -Destination $local -Force -ErrorAction Stop
        } catch {
            if (-not $StartFailures.ContainsKey($id)) { $StartFailures[$id] = Get-Date }
            if (((Get-Date) - $StartFailures[$id]).TotalSeconds -lt 15) { continue }
            Write-AgentLog "command $id could not be read: $($_.Exception.Message)"
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            $StartFailures.Remove($id)
            Write-ShareFile "cmd-out\$id.exit" '-1'
            continue
        }
        $StartFailures.Remove($id)
        try {
            Remove-Item -Path $f.FullName -Force -ErrorAction Stop
            New-Item -ItemType Directory -Force -Path "$Share\cmd-out" -ErrorAction SilentlyContinue | Out-Null
            [IO.File]::WriteAllBytes($shareOut, [byte[]]@())
            [IO.File]::WriteAllBytes($out, [byte[]]@())
            $p = Start-Process -FilePath cmd.exe -WindowStyle Hidden -PassThru -ArgumentList `
                "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$local`" > `"$out`" 2>&1"
            $null = $p.Handle
            $Running[$id] = @{ Proc = $p; Out = $out; ShareOut = $shareOut; Local = $local; Offset = [long]0; Cancelled = $false }
            Write-AgentLog "command $id start"
        } catch {
            Write-AgentLog "command $id could not start: $($_.Exception.Message)"
            Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
            Write-ShareFile "cmd-out\$id.exit" '-1'
        }
    }
}

function Update-RunningCommands {
    foreach ($id in @($Running.Keys)) {
        $c = $Running[$id]
        $c.Offset = Copy-NewBytes $c.Out $c.ShareOut $c.Offset
        if (-not $c.Cancelled -and (Test-Path "$Share\cmd\$id.cancel")) {
            & taskkill.exe /T /F /PID $c.Proc.Id 2>&1 | Out-Null
            Remove-Item "$Share\cmd\$id.cancel" -Force -ErrorAction SilentlyContinue
            $c.Cancelled = $true
            Write-AgentLog "command $id cancelled"
        }
        if (-not $c.Proc.HasExited) { continue }
        do { $before = $c.Offset; $c.Offset = Copy-NewBytes $c.Out $c.ShareOut $c.Offset } while ($c.Offset -ne $before)
        $code = -1
        try { $code = $c.Proc.ExitCode } catch { }
        if ($c.Cancelled) { $code = 124 }
        Write-ShareFile "cmd-out\$id.exit" "$code"
        Remove-Item -Path $c.Local, $c.Out -Force -ErrorAction SilentlyContinue
        $Running.Remove($id)
        Write-AgentLog "command $id exit $code"
    }
}

# ---------------------------------------------------------------- startup
for ($i = 0; $i -lt 120 -and -not (Test-Path $Share); $i++) { Start-Sleep -Seconds 2 }
Write-AgentLog "agent start boot=$BootId sinceBoot=${AgentUptime}s"

# The SMB client caches directory listings and file metadata for up to 10 s, which delays every command picked up from
# \\host.lan\Data\cmd by that much. The seal bakes these settings; this covers older images.
try {
    $smb = Get-SmbClientConfiguration
    if ($smb.DirectoryCacheLifetime -or $smb.FileInfoCacheLifetime -or $smb.FileNotFoundCacheLifetime) {
        Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileInfoCacheLifetime 0 -FileNotFoundCacheLifetime 0 -Confirm:$false
        Write-AgentLog 'SMB client metadata caches turned off'
    }
} catch { Write-AgentLog "SMB client cache settings: $($_.Exception.Message)" }

$bootInfo = [ordered]@{
    bootId = $BootId; lastBootUtc = Get-Iso (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; agentStartUtc = Get-Iso $AgentStart
    agentSinceBootSec = $AgentUptime; shareSinceBootSec = Get-UptimeSec
    agentFile = (Get-FileHash $PSCommandPath).Hash.Substring(0, 12)
    computerName = $env:COMPUTERNAME; timeZone = (Get-TimeZone).Id
    ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -ExpandProperty IPAddress)
}
Write-ShareFile 'agent\boot.json' ($bootInfo | ConvertTo-Json -Depth 4)

# ---------------------------------------------------------------- runtime settings (license first: no service needed)
$Runtime = [ordered]@{ bootId = $BootId; status = 'none'; adminPassword = 'not-requested'; adminPasswordSec = $null
    licenseUser = 'not-requested'; licenseFiles = @(); errors = @() }
$PendingPassword = $null
$rcPath = "$Share\runtime\config.json"
if (Test-Path $rcPath) {
    try {
        $rc = (Get-Content $rcPath -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
        $Runtime.status = 'pending'
        if ($rc.PSObject.Properties['adminPassword'] -and $rc.adminPassword) { $PendingPassword = [string]$rc.adminPassword; $Runtime.adminPassword = 'pending' }
        if ($rc.PSObject.Properties['licenseUser'] -and $rc.licenseUser) {
            $u = [string]$rc.licenseUser
            if ($u -notmatch '^[A-Za-z0-9._-]{1,20}$') { throw "SLS_LICENSE_USER '$u' is not a valid local account name (1-20 of A-Z a-z 0-9 . _ -)" }
            if (Get-LocalUser -Name $u -ErrorAction SilentlyContinue) { $Runtime.licenseUser = "exists:$u" }
            else {
                $pw = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
                New-LocalUser -Name $u -Password $pw -PasswordNeverExpires -AccountNeverExpires -Description 'SystemLink license user' -ErrorAction Stop | Out-Null
                Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $u -ErrorAction SilentlyContinue
                Add-Content -Path $PlacedList -Value "user:$u" -Encoding ascii
                $Runtime.licenseUser = "created:$u"
            }
            Write-AgentLog "license user $($Runtime.licenseUser)"
        }
    } catch {
        $Runtime.errors += "runtime config: $($_.Exception.Message)"
        Write-AgentLog "ERROR runtime config: $($_.Exception.Message)"
    } finally { Remove-Item $rcPath -Force -ErrorAction SilentlyContinue }
}
$lics = @(Get-ChildItem -Path "$Share\runtime\licenses" -Filter '*.lic' -File -ErrorAction SilentlyContinue)
if ($lics) {
    if ($Runtime.status -eq 'none') { $Runtime.status = 'pending' }
    New-Item -ItemType Directory -Force -Path $LicenseDir | Out-Null
    foreach ($l in $lics) {
        try {
            Copy-Item -Path $l.FullName -Destination $LicenseDir -Force -ErrorAction Stop
            Add-Content -Path $PlacedList -Value "file:$(Join-Path $LicenseDir $l.Name)" -Encoding ascii
            $Runtime.licenseFiles += [ordered]@{ name = $l.Name; bytes = $l.Length; sha256 = (Get-FileHash (Join-Path $LicenseDir $l.Name)).Hash }
            Remove-Item $l.FullName -Force -ErrorAction SilentlyContinue
            Write-AgentLog "license file placed: $($l.Name) -> $LicenseDir"
        } catch {
            $Runtime.errors += "license $($l.Name): $($_.Exception.Message)"
            Write-AgentLog "ERROR license $($l.Name): $($_.Exception.Message)"
        }
    }
}
Write-ShareFile 'agent\runtime.json' ($Runtime | ConvertTo-Json -Depth 4)

# ---------------------------------------------------------------- main loop
# Phases: wait-http -> [set-password -> wait-auth] -> ready -> done; failed stops before ready (container unhealthy).
$Phase = if ($Runtime.errors) { 'failed' } else { 'wait-http' }
if ($Phase -eq 'failed') { $Runtime.status = 'failed'; Write-ShareFile 'agent\runtime.json' ($Runtime | ConvertTo-Json -Depth 4) }
$servicesAt = $null
$coreAt = $null
$lagging = @()
$httpAt = $null
$httpCode = 0
$wsProc = $null
$pwStart = $null
$authDeadline = $null
$lastStatus = [datetime]::MinValue

function Set-Failed([string]$Message) {
    $script:Runtime.errors += $Message
    $script:Runtime.status = 'failed'
    $script:PendingPassword = $null
    Write-ShareFile 'agent\runtime.json' ($script:Runtime | ConvertTo-Json -Depth 4)
    Write-AgentLog "ERROR $Message (container stays unhealthy)"
    $script:Phase = 'failed'
}

while ($true) {
    switch ($Phase) {
        'wait-http' {
            $states = Get-ServiceStates
            $coreOk = -not ($ReadyServices | Where-Object { $states[$_] -ne 'Running' })
            if ($coreOk -and $null -eq $coreAt) { $coreAt = Get-Date }
            $lagging = @($AutoServices | Where-Object { $states[$_] -ne 'Running' })
            $svcOk = $coreOk -and (-not $lagging -or ((Get-Date) - $coreAt).TotalSeconds -ge $AutoServicesGraceSec)
            if ($svcOk -and $null -eq $servicesAt) {
                $servicesAt = Get-UptimeSec
                if ($lagging) { Write-AgentLog "not running after ${AutoServicesGraceSec}s grace: $(($lagging | ForEach-Object { "$_=$($states[$_])" }) -join ', ')" }
            }
            $httpCode = if ($svcOk) { Get-HttpStatus } else { 0 }
            if ($httpCode -in 200, 401) {
                $httpAt = Get-UptimeSec
                if (-not $PendingPassword) { $Phase = 'ready' }
                elseif (Test-PasswordMarker $PendingPassword) {
                    $Runtime.adminPassword = 'unchanged'; $PendingPassword = $null; $Phase = 'ready'
                    Write-AgentLog 'admin password already set to the requested value'
                } elseif (-not (Test-Path $WsCmd)) { Set-Failed "not found: $WsCmd" }
                else {
                    Write-AgentLog 'setting the admin password (web server setup)'
                    $pwStart = Get-Date
                    $wsProc = Start-Process -FilePath $WsCmd -ArgumentList ($WsSetupArgs -f $PendingPassword) -WindowStyle Hidden -PassThru `
                        -RedirectStandardOutput "$Root\webserver-setup.txt" -RedirectStandardError "$Root\webserver-setup.err.txt"
                    $null = $wsProc.Handle
                    $Phase = 'set-password'
                }
            }
        }
        'set-password' {
            if ($wsProc.HasExited) {
                if ($wsProc.ExitCode -eq 0) { $Phase = 'wait-auth'; $authDeadline = (Get-Date).AddMinutes(5) }
                else {
                    $first = (Get-Content "$Root\webserver-setup.txt", "$Root\webserver-setup.err.txt" -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Select-Object -Last 3) -join ' | '
                    Set-Failed "web server setup exit $($wsProc.ExitCode): $first"
                }
            } elseif (((Get-Date) - $pwStart).TotalMinutes -gt 10) {
                & taskkill.exe /T /F /PID $wsProc.Id 2>&1 | Out-Null
                Set-Failed 'web server setup did not finish within 10 minutes'
            }
        }
        'wait-auth' {
            if ((Get-HttpStatus 'niauth/v1/user' $AdminUser $PendingPassword) -eq 200) {
                Save-PasswordMarker $PendingPassword
                $PendingPassword = $null
                $Runtime.adminPassword = 'set'
                $Runtime.adminPasswordSec = [math]::Round(((Get-Date) - $pwStart).TotalSeconds, 1)
                $httpAt = Get-UptimeSec
                Write-AgentLog "admin password set ($($Runtime.adminPasswordSec)s)"
                $Phase = 'ready'
            } elseif ((Get-Date) -gt $authDeadline) { Set-Failed 'admin login with the new password still fails 5 minutes after the web server setup' }
        }
        'ready' {
            if ($Runtime.status -eq 'pending') { $Runtime.status = 'applied' }
            Write-ShareFile 'agent\runtime.json' ($Runtime | ConvertTo-Json -Depth 4)
            $readyInfo = [ordered]@{
                bootId = $BootId; readyUtc = Get-Iso (Get-Date); servicesSinceBootSec = $servicesAt; httpSinceBootSec = $httpAt
                readySinceBootSec = Get-UptimeSec; httpStatus = $httpCode; runtime = $Runtime.status; eval = Get-EvalInfo
                autoServices = $AutoServices.Count; servicesNotRunning = @($lagging)
            }
            Write-ShareFile 'agent\ready.json' ($readyInfo | ConvertTo-Json -Depth 4)
            Write-AgentLog "ready services=$($servicesAt)s http=$($httpAt)s ready=$($readyInfo.readySinceBootSec)s runtime=$($Runtime.status)"
            $Phase = 'done'
        }
    }
    if ($Phase -notin 'done', 'failed' -and ((Get-Date) - $lastStatus).TotalSeconds -ge 30) {
        Write-ShareFile 'agent\status.json' ([ordered]@{ bootId = $BootId; utc = Get-Iso (Get-Date); phase = $Phase; services = Get-ServiceStates; http = $httpCode } | ConvertTo-Json)
        $lastStatus = Get-Date
    }
    try { Start-QueuedCommands; Update-RunningCommands } catch { Write-AgentLog "command channel error: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds $(if ($Running.Count) { 300 } else { 1000 })
}
