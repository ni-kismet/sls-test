# SystemLink Server container test kit (PowerShell 7). Starts SystemLink Server containers for integration tests,
# waits until they are usable, calls the REST API, runs scripts in the Windows guest and collects logs.
#
#   Import-Module ./src/testkit/SlsTestKit.psm1
#   $s = Start-SlsServer -Image sls-server:26.5-demo                            # returns once healthy
#   Invoke-SlsApi $s 'nitag/v2/tags?take=10'
#   Wait-SlsCondition { (Invoke-SlsApi $s 'nitag/v2/tags/demo.line1.sensor001/values/current').value.value -eq '1.25' }
#   Invoke-SlsGuest $s 'Get-Service NI* | Format-Table -AutoSize'
#   Save-SlsLogs $s -Path ./test-logs                                           # on failure
#   Stop-SlsServer $s
#
# Secrets (admin password, health credentials) reach docker through the inherited environment, never on the command
# line. Containers publish port 80 on 127.0.0.1 only, on a free port chosen by docker. Without -Credential or
# -AdminCredential the API helpers sign in as admin / test (the images' default web admin password).
Set-StrictMode -Version Latest

$script:DefaultImage = 'sls-server:26.5'
$script:DefaultCredential = [pscredential]::new('admin', (ConvertTo-SecureString 'test' -AsPlainText -Force))

function Invoke-SlsDockerCli {
    # Not an advanced function: docker flags such as -v/-p must not bind to PowerShell common parameters.
    $out = & docker @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed ($LASTEXITCODE): $(($out | Select-Object -Last 5) -join ' | ')" }
    return $out
}

function Get-SlsDockerLogTail([string]$Name, [int]$Lines = 15) {
    return ((& docker logs --tail $Lines $Name 2>&1) | ForEach-Object { "  $_" }) -join "`n"
}

function New-SlsServerObject([string]$Name, [string]$Image, [pscredential]$Credential, [string]$LicenseDir) {
    $port = "$(Invoke-SlsDockerCli port $Name 80/tcp | Select-Object -First 1)".Trim()
    if ($port -notmatch ':(\d+)$') { throw "container $Name does not publish port 80 (docker port: '$port')" }
    $p = [int]$matches[1]
    $hostPart = $port.Substring(0, $port.LastIndexOf(':'))
    if ($hostPart -in '0.0.0.0', '[::]', '::') { $hostPart = '127.0.0.1' }
    return [pscustomobject]@{
        PSTypeName = 'SlsServer'; Name = $Name; Image = $Image; HttpPort = $p; BaseUrl = "http://${hostPart}:$p"
        Credential = $Credential; LicenseDir = $LicenseDir; StartedUtc = [DateTime]::UtcNow
    }
}

function Get-SlsServer {
    <#
    .SYNOPSIS
    Returns a server object for an existing container (for example one started with docker compose).
    #>
    param([Parameter(Mandatory)][string]$Name, [pscredential]$Credential)
    $image = "$(Invoke-SlsDockerCli inspect -f '{{.Config.Image}}' $Name)".Trim()
    if (-not $Credential) { $Credential = $script:DefaultCredential }
    return New-SlsServerObject -Name $Name -Image $image -Credential $Credential -LicenseDir $null
}

function Start-SlsServer {
    <#
    .SYNOPSIS
    Starts a SystemLink Server container and (unless -NoWait) waits until it is healthy.
    .PARAMETER AdminCredential
    Sets the web "admin" password at start (SLS_ADMIN_PASSWORD; the user name must be admin). The healthcheck and the
    API helpers then authenticate with it.
    .PARAMETER Credential
    Credentials already valid in the image (for example the image build's admin password). Used for the authenticated
    healthcheck (SLS_HEALTH_AUTH) and the API helpers; nothing is changed in the guest.
    .PARAMETER LicenseFile
    User-based license files, mounted read-only at /licenses and placed in the guest's license folder before ready.
    .PARAMETER Volume
    Named volume for /storage: the container becomes persistent (the disk survives the container).
    .PARAMETER DockerArgs
    Extra docker run arguments, added before the image name.
    #>
    param(
        [string]$Image = $(if ($env:SLS_IMAGE) { $env:SLS_IMAGE } else { $script:DefaultImage }),
        [string]$Name = "sls-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))",
        [pscredential]$AdminCredential,
        [pscredential]$Credential,
        [string]$LicenseUser,
        [string[]]$LicenseFile = @(),
        [string]$Config,
        [string]$Volume,
        [string]$Ram = '8G',
        [int]$Cpu = 4,
        [int]$HttpPort = 0,
        [string]$Network,
        [hashtable]$Env = @{},
        [string[]]$DockerArgs = @(),
        [int]$TimeoutSec = 900,
        [switch]$NoWait
    )
    if ($AdminCredential -and $AdminCredential.UserName -ne 'admin') { throw "AdminCredential: the user name must be 'admin' (got '$($AdminCredential.UserName)')" }
    # Without credentials the healthcheck stays anonymous; the API helpers use the default admin / test.
    $cred = if ($AdminCredential) { $AdminCredential } elseif ($Credential) { $Credential } else { $script:DefaultCredential }
    $a = @('run', '-d', '--name', $Name, '--device', '/dev/kvm', '--device', '/dev/net/tun', '--cap-add', 'NET_ADMIN',
        '--stop-timeout', '150', '-e', "RAM_SIZE=$Ram", '-e', "CPU_CORES=$Cpu",
        '-p', $(if ($HttpPort) { "127.0.0.1:${HttpPort}:80" } else { '127.0.0.1::80' }))
    if ($Config) { $a += @('-e', "SLS_CONFIG=$Config") }
    if ($Volume) { $a += @('-v', "${Volume}:/storage") }
    if ($Network) { $a += @('--network', $Network) }
    if ($LicenseUser) { $a += @('-e', "SLS_LICENSE_USER=$LicenseUser") }
    foreach ($k in $Env.Keys) { $a += @('-e', "$k=$($Env[$k])") }
    $a += $DockerArgs
    $licenseDir = $null
    if ($LicenseFile) {
        $licenseDir = Join-Path ([IO.Path]::GetTempPath()) "sls-licenses-$Name"
        New-Item -ItemType Directory -Force -Path $licenseDir | Out-Null
        foreach ($f in $LicenseFile) { Copy-Item -LiteralPath $f -Destination $licenseDir -Force }
        $a += @('-v', "${licenseDir}:/licenses:ro")
    }
    $secrets = [ordered]@{}
    if ($AdminCredential) { $secrets['SLS_ADMIN_PASSWORD'] = $AdminCredential.GetNetworkCredential().Password }
    elseif ($Credential) { $secrets['SLS_HEALTH_AUTH'] = "$($Credential.UserName):$($Credential.GetNetworkCredential().Password)" }
    foreach ($k in $secrets.Keys) { $a += @('-e', $k) }
    $a += $Image

    $saved = @{}
    foreach ($k in $secrets.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $secrets[$k]) }
    try { Invoke-SlsDockerCli @a | Out-Null }
    finally { foreach ($k in $secrets.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }

    $server = New-SlsServerObject -Name $Name -Image $Image -Credential $cred -LicenseDir $licenseDir
    if (-not $NoWait) {
        try { Wait-SlsServer $server -TimeoutSec $TimeoutSec | Out-Null }
        catch { $server | Add-Member -NotePropertyName StartError -NotePropertyValue $_.Exception.Message; throw }
    }
    return $server
}

function Restart-SlsServer {
    <#
    .SYNOPSIS
    Shuts Windows down cleanly (docker stop -t 150), starts the container again and waits until it is healthy (the
    agent gates readiness again; runtime settings are re-applied). Updates HttpPort/BaseUrl in place: a port published
    as 127.0.0.1::80 changes on every start. Returns the server object.
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [int]$TimeoutSec = 900)
    Invoke-SlsDockerCli stop -t 150 $Server.Name | Out-Null
    Invoke-SlsDockerCli start $Server.Name | Out-Null
    $fresh = New-SlsServerObject -Name $Server.Name -Image $Server.Image -Credential $Server.Credential -LicenseDir $Server.LicenseDir
    $Server.HttpPort = $fresh.HttpPort
    $Server.BaseUrl = $fresh.BaseUrl
    $Server.StartedUtc = $fresh.StartedUtc
    Wait-SlsServer $Server -TimeoutSec $TimeoutSec | Out-Null
    return $Server
}

function Get-SlsAgentFile($Server, [string]$Path) {
    $name = if ($Server -is [string]) { $Server } else { $Server.Name }
    $t = (& docker exec $name cat "/shared/$Path" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or -not $t) { return $null }
    try { return $t.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { return $null }
}

function Wait-SlsServer {
    <#
    .SYNOPSIS
    Waits until the container is healthy (guest agent ready, runtime settings applied, API answering). Fails fast when
    the container stops or the agent reports a runtime settings failure. Returns seconds waited.
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [int]$TimeoutSec = 900)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $state = "$(& docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' $Server.Name 2>$null)".Trim()
        $status, $health = $state -split '\|', 2
        if ($health -eq 'healthy') { return [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        if ($status -ne 'running') { throw "container $($Server.Name) is $(if ($status) { $status } else { 'gone' }):`n$(Get-SlsDockerLogTail $Server.Name)" }
        $rt = Get-SlsAgentFile $Server 'agent/runtime.json'
        if ($rt -and $rt.status -eq 'failed') { throw "runtime settings failed in $($Server.Name): $($rt.errors -join '; ')" }
        # Unhealthy only counts after the 15 min start period; a bugcheck while booting is caught here.
        $panic = "$(& docker exec $Server.Name sh -c 'cat ${STORAGE:-/storage}/sls-panic.txt 2>/dev/null' 2>$null)".Trim()
        if ($panic) { throw "Windows bugcheck in $($Server.Name) ($panic); the guest is paused, see /storage/sls-panic.ppm:`n$(Get-SlsDockerLogTail $Server.Name)" }
        if ($health -eq 'unhealthy') { throw "container $($Server.Name) is unhealthy:`n$(Get-SlsDockerLogTail $Server.Name)" }
        Start-Sleep -Seconds 2
    }
    throw "container $($Server.Name) not healthy after $TimeoutSec s:`n$(Get-SlsDockerLogTail $Server.Name)"
}

function Wait-SlsCondition {
    <#
    .SYNOPSIS
    Polls a script block until it returns a truthy value (exceptions count as false). Returns that value; throws on
    timeout with the last error. SystemLink services can lag the healthcheck by a few seconds: poll, don't sleep.
    #>
    param([Parameter(Mandatory, Position = 0)][scriptblock]$Condition, [int]$TimeoutSec = 120, [int]$IntervalMs = 1000,
        [string]$Message = 'condition')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    do {
        try { $r = & $Condition; if ($r) { return $r } } catch { $last = $_.Exception.Message }
        Start-Sleep -Milliseconds $IntervalMs
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    throw "timed out after $TimeoutSec s waiting for $Message$(if ($last) { " (last error: $last)" })"
}

$script:Http = $null
function Get-SlsHttpClient {
    if (-not $script:Http) {
        $h = [Net.Http.HttpClientHandler]::new()
        $h.AllowAutoRedirect = $false
        $h.UseCookies = $false
        $script:Http = [Net.Http.HttpClient]::new($h)
        $script:Http.Timeout = [TimeSpan]::FromSeconds(60)
    }
    return $script:Http
}

function Invoke-SlsApi {
    <#
    .SYNOPSIS
    Calls the SystemLink REST API with the server's credentials. -Body objects are sent as JSON; -Content sends any
    HttpContent (for example multipart uploads). Returns the parsed JSON (or text); throws on non-2xx unless -PassThru,
    which returns Status/Body/Json instead.
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [Parameter(Mandatory, Position = 1)][string]$Path,
        [string]$Method = 'GET', $Body = $null, [Net.Http.HttpContent]$Content = $null, [pscredential]$Credential,
        [switch]$Anonymous, [switch]$PassThru)
    $url = if ($Path -match '^https?://') { $Path } else { "$($Server.BaseUrl)/$($Path.TrimStart('/'))" }
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $url)
    $cred = if ($Credential) { $Credential } else { $Server.Credential }
    if ($cred -and -not $Anonymous) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($cred.UserName):$($cred.GetNetworkCredential().Password)"))
        $req.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', $b64)
    }
    if ($Content) { $req.Content = $Content }
    elseif ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $req.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
    }
    $resp = (Get-SlsHttpClient).SendAsync($req).GetAwaiter().GetResult()
    try {
        $status = [int]$resp.StatusCode
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally { $resp.Dispose(); $req.Dispose() }
    $parsed = $null
    if ($text) { try { $parsed = $text | ConvertFrom-Json -Depth 50 } catch { $parsed = $null } }
    if ($PassThru) { return [pscustomobject]@{ Status = $status; Body = $text; Json = $parsed } }
    if ($status -lt 200 -or $status -ge 300) {
        $snippet = if ($text) { $text.Substring(0, [Math]::Min(300, $text.Length)) } else { '' }
        throw "$Method $url -> $status $snippet"
    }
    if ($null -ne $parsed) { return $parsed }
    return $text
}

function Invoke-SlsGuest {
    <#
    .SYNOPSIS
    Runs a PowerShell script in the Windows guest as SYSTEM (Windows PowerShell 5.1) through sls-exec. Returns
    ExitCode and Output; throws on a non-zero exit code unless -NoThrow.
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [Parameter(Mandatory, Position = 1)][string]$Script,
        [int]$TimeoutSec = 600, [switch]$NoThrow)
    $name = if ($Server -is [string]) { $Server } else { $Server.Name }
    $out = $Script | & docker exec -i $name sls-exec -t $TimeoutSec 2>&1
    $code = $LASTEXITCODE
    $lines = @($out | ForEach-Object { "$_" })
    if ($code -ne 0 -and -not $NoThrow) { throw "guest script exit $code in ${name}:`n$(($lines | Select-Object -Last 20) -join "`n")" }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

function Save-SlsLogs {
    <#
    .SYNOPSIS
    Collects the guest logs (sls-logs) and the container log into -Path. Returns the files written. After a Windows
    bugcheck it adds sls-panic.txt and the last screen (sls-panic.ppm) and skips the guest logs (the guest is paused).
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [string]$Path = '.', [int]$TimeoutSec = 600)
    $name = if ($Server -is [string]) { $Server } else { $Server.Name }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $files = @()
    $dockerLog = Join-Path $Path "$name-$stamp-docker.log"
    & docker logs -t $name *> $dockerLog
    $files += $dockerLog
    # sls-panic-watch's record of a bugcheck and the last screen before it (the blue screen, or the frame before).
    $panic = ''
    foreach ($f in 'sls-panic.txt', 'sls-panic.ppm') {
        $dest = Join-Path $Path "$name-$stamp-$f"
        & docker cp "${name}:/storage/$f" $dest 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dest)) { $files += $dest; if ($f -like '*.txt') { $panic = (Get-Content $dest -Raw).Trim() } }
    }
    $running = "$(& docker inspect -f '{{.State.Running}}' $name 2>$null)" -eq 'true'
    # Images before the sls-logs bugcheck check would wait out -TimeoutSec on the paused guest.
    if ($panic) { Write-Warning "Windows bugcheck in ${name} ($panic): skipping guest logs" }
    elseif ($running) {
        $progress = & docker exec $name sls-logs -t $TimeoutSec -o /tmp/sls-logs.tgz 2>&1
        $tgz = Join-Path $Path "$name-$stamp-logs.tgz"
        & docker cp "${name}:/tmp/sls-logs.tgz" $tgz 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $files += $tgz; & docker exec $name rm -f /tmp/sls-logs.tgz 2>&1 | Out-Null }
        else { Write-Warning "sls-logs failed in ${name}: $($progress -join ' | ')" }
    }
    return $files
}

function Stop-SlsServer {
    <#
    .SYNOPSIS
    Removes the container (and its anonymous volumes). -Graceful shuts Windows down first (needed before reusing a
    persistent -Volume); -RemoveVolume also deletes the named volume.
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [switch]$Graceful, [switch]$RemoveVolume)
    $name = if ($Server -is [string]) { $Server } else { $Server.Name }
    $vols = @()
    if ($RemoveVolume) { $vols = @(& docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' $name 2>$null) -split ' ' | Where-Object { $_ } }
    if ($Graceful) { & docker stop -t 150 $name 2>&1 | Out-Null }
    & docker rm -f -v $name 2>&1 | Out-Null
    foreach ($v in $vols) { & docker volume rm $v 2>&1 | Out-Null }
    if ($Server -isnot [string] -and $Server.LicenseDir -and (Test-Path $Server.LicenseDir)) { Remove-Item $Server.LicenseDir -Recurse -Force }
}

$script:CoverageChecks = @(
    # One read-only call per migration resource (sls-test docs/workflow-test-plan.md §2). Routes confirmed on 26.5.
    @{ Resource = 'workspaces'; Method = 'GET'; Path = 'niuser/v1/workspaces?take=1' }
    @{ Resource = 'users'; Method = 'POST'; Path = 'niuser/v1/users/query'; Body = @{ take = 1 } }
    @{ Resource = 'files'; Method = 'GET'; Path = 'nifile/v1/service-groups/Default/files?take=1' }
    @{ Resource = 'testmonitor-products'; Method = 'POST'; Path = 'nitestmonitor/v2/query-products'; Body = @{ take = 1 } }
    @{ Resource = 'testmonitor-results'; Method = 'POST'; Path = 'nitestmonitor/v2/query-results'; Body = @{ take = 1 } }
    @{ Resource = 'testmonitor-steps'; Method = 'POST'; Path = 'nitestmonitor/v2/query-steps'; Body = @{ take = 1 } }
    @{ Resource = 'feeds'; Method = 'GET'; Path = 'nirepo/v1/feeds' }
    @{ Resource = 'assets'; Method = 'POST'; Path = 'niapm/v1/query-assets'; Body = @{ take = 1 } }
    @{ Resource = 'states'; Method = 'GET'; Path = 'nisystemsstate/v1/states?take=1' }
    @{ Resource = 'systems'; Method = 'POST'; Path = 'nisysmgmt/v1/query-systems'; Body = @{ skip = 0; take = 1 } }
)

function Test-SlsServiceCoverage {
    <#
    .SYNOPSIS
    Calls one read-only endpoint per migration resource (workspaces, users, files, Test Monitor, feeds, assets, states,
    systems). Returns one row per resource: Result ok (2xx), license (402/403: module needs a license) or failed
    (anything else, including 404 = service not installed). -Throw fails on any failed row.
    .PARAMETER WaitSec
    Retries rows that look like a service still starting (no response, 502, 503, 504) until this many seconds have
    passed. Module services can lag the healthcheck: Test Monitor answers about 30 s after healthy.
    #>
    param([Parameter(Mandatory, Position = 0)]$Server, [int]$WaitSec = 0, [switch]$Throw)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $byResource = [ordered]@{}
    $pending = $script:CoverageChecks
    while ($true) {
        foreach ($c in $pending) {
            $r = try { Invoke-SlsApi $Server $c.Path -Method $c.Method -Body $c['Body'] -PassThru } catch { [pscustomobject]@{ Status = 0; Body = $_.Exception.Message } }
            $result = if ($r.Status -ge 200 -and $r.Status -lt 300) { 'ok' } elseif ($r.Status -in 402, 403) { 'license' } else { 'failed' }
            $detail = if ($result -eq 'ok' -or -not $r.Body) { '' } else { $r.Body.Substring(0, [Math]::Min(200, $r.Body.Length)) }
            $byResource[$c.Resource] = [pscustomobject]@{ Resource = $c.Resource; Route = "$($c.Method) /$($c.Path)"; Status = $r.Status; Result = $result; Detail = $detail; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
        }
        $pending = @($script:CoverageChecks | Where-Object { $byResource[$_.Resource].Status -in 0, 502, 503, 504 })
        if (-not $pending -or $sw.Elapsed.TotalSeconds -ge $WaitSec) { break }
        Start-Sleep -Seconds 5
    }
    $rows = @($byResource.Values)
    $bad = @($rows | Where-Object Result -eq 'failed')
    if ($Throw -and $bad) { throw "service coverage: $(($bad | ForEach-Object { "$($_.Resource) $($_.Status)" }) -join ', ')" }
    return $rows
}

Export-ModuleMember -Function Start-SlsServer, Get-SlsServer, Wait-SlsServer, Restart-SlsServer, Wait-SlsCondition, Invoke-SlsApi, Invoke-SlsGuest,
    Save-SlsLogs, Stop-SlsServer, Get-SlsAgentFile, Test-SlsServiceCoverage
