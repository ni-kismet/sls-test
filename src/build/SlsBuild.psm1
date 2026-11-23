# SystemLink Server image build helpers (PowerShell 7). Imported by Build-SlsImage.ps1, the stage scripts and
# New-SlsConfigImage.ps1. Consumer-facing helpers (start/wait/API/guest/logs) live in src/testkit/SlsTestKit.psm1.
Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:DefaultDockurImage = 'dockurr/windows@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea'
$script:LogFile = $null

function Get-SlsRepoRoot { $script:RepoRoot }
function Get-SlsDefaultDockurImage { $script:DefaultDockurImage }
# Build output (logs, reports, credentials.json): SLS_OUT (the actions use $RUNNER_TEMP/sls), else src/out.
function Get-SlsOutRoot { if ($env:SLS_OUT) { $env:SLS_OUT } else { Join-Path $script:RepoRoot 'out' } }
# Web admin password of the images: not a secret (local test servers); SLS_BUILD_ADMIN_PASSWORD overrides it.
$script:DefaultAdminPassword = 'test'
function Get-SlsAdminPassword { if ($env:SLS_BUILD_ADMIN_PASSWORD) { $env:SLS_BUILD_ADMIN_PASSWORD } else { $script:DefaultAdminPassword } }

function Set-SlsLogFile([string]$Path) {
    $script:LogFile = $Path
    if ($Path) { New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null }
}

function Write-SlsLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 }
}

function Invoke-SlsDocker {
    # Not an advanced function: docker flags such as -v/-p must not bind to PowerShell common parameters.
    $out = & docker @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed ($LASTEXITCODE): $(($out | Select-Object -Last 8) -join ' | ')" }
    return $out
}

function Test-SlsContainer([string]$Name) {
    $null = & docker inspect --type container $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-SlsRunning([string]$Name) { "$(& docker inspect -f '{{.State.Running}}' $Name 2>$null)" -eq 'true' }

function Remove-SlsContainer([string]$Name) {
    if (Test-SlsContainer $Name) { & docker rm -f -v $Name 2>&1 | Out-Null }
}

function Test-SlsImage([string]$Name) {
    $null = & docker image inspect $Name 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-SlsHelper {
    # Runs a shell snippet in a throwaway container (default: the pinned dockur image, which has qemu-img/jq/curl).
    param([Parameter(Mandatory)][string]$Script, [string[]]$Volumes = @(), [string]$Image = $script:DefaultDockurImage)
    $a = @('run', '--rm', '--entrypoint', 'sh')
    foreach ($v in $Volumes) { $a += @('-v', $v) }
    $a += @($Image, '-c', ($Script -replace "`r", ''))
    $out = & docker @a 2>&1
    if ($LASTEXITCODE -ne 0) { throw "helper failed ($LASTEXITCODE): $(($out | Select-Object -Last 8) -join ' | ')" }
    return $out
}

function Get-SlsVolumeUsageBytes([string]$Volume, [string]$Path = '.') {
    # Allocated bytes of a (sparse) file or a directory inside a volume.
    $kb = Invoke-SlsHelper -Image 'alpine:3' -Volumes @("${Volume}:/v:ro") -Script "du -sk '/v/$Path' | cut -f1"
    return [int64]("$kb".Trim()) * 1024
}

function Read-SlsShared([string]$Container, [string]$Path) {
    # A file from the container's /shared (the guest's \\host.lan\Data); $null when missing.
    $text = (& docker exec $Container cat "/shared/$Path" 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0) { return $null }
    return $text.TrimStart([char]0xFEFF)
}

function Read-SlsSharedJson([string]$Container, [string]$Path) {
    $t = Read-SlsShared $Container $Path
    if (-not $t) { return $null }
    try { return $t | ConvertFrom-Json } catch { return $null }
}

function Invoke-SlsGuestScript {
    # Runs a PowerShell script in the guest through sls-exec, logs its output (prefixed) and returns the exit code.
    param([Parameter(Mandatory)][string]$Container, [Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 600,
        [string]$Label = 'guest', [string]$OutFile)
    Write-SlsLog "$Label`: running in the guest (timeout ${TimeoutSec}s)"
    $lines = [Collections.Generic.List[string]]::new()
    $Script | & docker exec -i $Container sls-exec -t $TimeoutSec 2>&1 | ForEach-Object {
        $l = "$_"
        $lines.Add($l)
        Write-SlsLog "  $Label | $l"
    }
    $code = $LASTEXITCODE
    if ($OutFile) { Set-Content -Path $OutFile -Value $lines -Encoding utf8 }
    Write-SlsLog "$Label`: exit $code"
    Assert-SlsNoGuestPanic $Container
    return $code
}

function Assert-SlsNoGuestPanic([string]$Container) {
    # Throws when sls-panic-watch recorded a Windows bugcheck (QEMU paused the VM as guest-panicked).
    $p = (& docker exec $Container cat /storage/sls-panic.txt 2>$null) -join ' '
    if ($LASTEXITCODE -eq 0 -and $p) {
        throw "Windows bugcheck in the build VM $Container ($($p.Trim())); blue screen in ${Container}:/storage/sls-panic.ppm. On nested KVM hosts keep Hyper-V enlightenments off (no -HyperV)."
    }
}

function Wait-SlsAgentReady {
    # Waits for agent/ready.json of a boot other than $PreviousBootId; returns it.
    param([string]$Container, [string]$PreviousBootId = '', [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Read-SlsSharedJson $Container 'agent/ready.json'
        if ($r -and $r.bootId -and $r.bootId -ne $PreviousBootId) { return $r }
        $rt = Read-SlsSharedJson $Container 'agent/runtime.json'
        if ($rt -and $rt.status -eq 'failed' -and $rt.bootId -ne $PreviousBootId) { throw "agent runtime settings failed: $($rt.errors -join '; ')" }
        if (-not (Test-SlsRunning $Container)) { throw "container $Container stopped while waiting for the agent" }
        Assert-SlsNoGuestPanic $Container
        Start-Sleep -Seconds 3
    }
    throw "timed out after $TimeoutSec s waiting for agent ready on $Container"
}

function Wait-SlsExit([string]$Container, [int]$TimeoutSec = 900) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-SlsRunning $Container)) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function New-SlsPassword([string]$Prefix = 'Sls-') {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $bytes = [byte[]]::new(20)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return $Prefix + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
}

function New-SlsCredential([string]$User, [string]$Password) {
    return [pscredential]::new($User, (ConvertTo-SecureString $Password -AsPlainText -Force))
}

function Register-SlsSecret([string[]]$Value) {
    # GitHub Actions: masks the values in all later log output. Written straight to stdout, never through Write-SlsLog
    # (build.log is a CI artifact).
    # The default password is not a secret (masking it would hide every "test" in the logs).
    if ($env:GITHUB_ACTIONS -ne 'true') { return }
    foreach ($v in $Value) { if ($v -and $v -ne $script:DefaultAdminPassword) { [Console]::Out.WriteLine("::add-mask::$v") } }
}

function Write-SlsCiOutput([Collections.IDictionary]$Values) {
    # GitHub Actions step outputs (name=value lines in $GITHUB_OUTPUT); no-op elsewhere.
    if (-not $env:GITHUB_OUTPUT) { return }
    foreach ($k in $Values.Keys) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$k=$($Values[$k])" -Encoding utf8 }
}

function Resolve-SlsTag([string]$Repository, [string]$Tag) {
    # A full reference (repo:tag) as is; a bare tag (no '/' or ':', which tags cannot contain) goes on -Repository.
    if ($Tag -match '[/:]') { return $Tag }
    return "${Repository}:$Tag"
}

function Get-SlsImageCredential {
    # Admin credential of an image: SLS_BUILD_ADMIN_PASSWORD, else the build's git-ignored credentials.json found
    # through the image's com.ni.sls.build-id label, else the default password.
    param([Parameter(Mandatory)][string]$Image)
    if ($env:SLS_BUILD_ADMIN_PASSWORD) { Register-SlsSecret $env:SLS_BUILD_ADMIN_PASSWORD; return New-SlsCredential 'admin' $env:SLS_BUILD_ADMIN_PASSWORD }
    $id = "$(& docker image inspect -f '{{ index .Config.Labels "com.ni.sls.build-id" }}' $Image 2>$null)".Trim()
    $f = Join-Path (Get-SlsOutRoot) "builds\$id\credentials.json"
    if (-not $id -or -not (Test-Path $f)) { return New-SlsCredential 'admin' $script:DefaultAdminPassword }
    $c = Get-Content $f -Raw | ConvertFrom-Json
    Register-SlsSecret $c.adminPassword, $c.vmPassword
    return New-SlsCredential $c.adminUser $c.adminPassword
}

function Test-SlsSeedScript {
    # Seed preflight (before any image work): the file exists, parses, and takes the contract's parameters
    # (-BaseUrl, -Credential, -Container, -Verify). Returns the full path.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "seed script $Path not found" }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
    if ($errors) { throw "seed script $Path does not parse: $(($errors | Select-Object -First 3 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')" }
    $params = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $missing = @('BaseUrl', 'Credential', 'Container', 'Verify' | Where-Object { $_ -notin $params })
    if ($missing) { throw "seed script $Path lacks the parameter(s) $($missing -join ', ') (contract: param(`$BaseUrl, `$Credential, `$Container, [switch]`$Verify))" }
    return $full
}

function Test-SlsTagRoundTrip {
    # Creates a DOUBLE tag, writes a value and reads it back (retries: the tag service can answer 500 for a few seconds
    # after authentication works). Returns $null on success, else the last error.
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)][string]$Path, [double]$Value = 42.5, [int]$TimeoutSec = 180,
        [switch]$Delete)
    $err = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        try {
            Invoke-SlsApi $Server "nitag/v2/tags/$Path" -Method PUT -Body @{ type = 'DOUBLE'; path = $Path; keywords = @('sls-build'); properties = @{} } | Out-Null
            Invoke-SlsApi $Server "nitag/v2/tags/$Path/values/current" -Method PUT -Body @{ value = @{ type = 'DOUBLE'; value = "$Value" } } | Out-Null
            Wait-SlsCondition { "$((Invoke-SlsApi $Server "nitag/v2/tags/$Path/values/current").value.value)" -eq "$Value" } -TimeoutSec 30 -Message "tag $Path" | Out-Null
            if ($Delete) { Invoke-SlsApi $Server "nitag/v2/tags/$Path" -Method DELETE | Out-Null }
            return $null
        } catch { $err = $_.Exception.Message; Start-Sleep -Seconds 3 }
    } while ((Get-Date) -lt $deadline)
    return $err
}

function Get-SlsGitInfo {
    $rev = "$(& git -C $script:RepoRoot rev-parse HEAD 2>$null)".Trim()
    $dirty = [bool](& git -C $script:RepoRoot status --porcelain 2>$null)
    # Credentials stripped; GitHub remotes normalized to https://github.com/<owner>/<repo> (the form GHCR uses to link
    # a package to its repository).
    $src = "$(& git -C $script:RepoRoot remote get-url origin 2>$null)".Trim() -replace '^(https?://)[^@/]+@', '$1'
    $src = $src -replace '^git@github\.com:', 'https://github.com/' -replace '^ssh://git@github\.com/', 'https://github.com/'
    if ($src -match '^https://github\.com/') { $src = $src -replace '\.git$', '' }
    # Used from another repository the action has no .git: name the action's repository and ref instead.
    if (-not $rev -and $env:SLS_ACTION_REPOSITORY) {
        $rev = "$env:SLS_ACTION_REPOSITORY@$env:SLS_ACTION_REF"
        if (-not $src) { $src = "https://github.com/$env:SLS_ACTION_REPOSITORY" }
    }
    return [pscustomobject]@{ Revision = $(if ($rev) { $rev + $(if ($dirty) { '-dirty' } else { '' }) } else { 'unknown' }); Source = $(if ($src) { $src } else { 'unknown' }) }
}

function Test-SlsDockerHost([int]$MinFreeGB = 60) {
    # Linux Docker engine (Docker Desktop WSL2 or native Linux), /dev/kvm for containers, free space in the Docker
    # data root (measured from a container, so it follows a moved data root such as /mnt/docker on CI runners).
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker CLI not found' }
    $os = "$(& docker info --format '{{.OSType}}' 2>$null)".Trim()
    if ($os -ne 'linux') { throw "Docker engine must be a Linux engine (Docker Desktop WSL2 backend or Docker on Linux); got '$os'" }
    & docker run --rm --device /dev/kvm alpine:3 test -c /dev/kvm 2>$null
    if ($LASTEXITCODE -ne 0) { throw '/dev/kvm is not available to containers (KVM, or nested virtualization under WSL2, required)' }
    $free = "$(Invoke-SlsHelper -Image 'alpine:3' -Script "df -k / | tail -1 | awk '{print `$4}'")".Trim()
    $freeGB = [math]::Round([int64]$free / 1MB, 1)
    if ($freeGB -lt $MinFreeGB) { throw "Docker has $freeGB GB free; the build needs about $MinFreeGB GB" }
    return $freeGB
}

Export-ModuleMember -Function *
