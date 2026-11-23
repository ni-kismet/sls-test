#Requires -Version 7.2
<#
.SYNOPSIS
Last job of build-images: records the images of the run (images.json + job summary) and, with -Promote, moves the
floating tags to them.

.DESCRIPTION
-BaseImage is the base image digest reference (<repo>@sha256:...); -SeedDir holds one image-<config>.json per seeded
image (written by the seed jobs: config, image = digest reference, tag, minutes, attempts, host_cpu); every name in
-Configs must have one.

Floating tags (-Promote): <repo>:<SlsVersion> and <repo>:<x.y.z> -> base; <repo>:<SlsVersion>-<config> and
<repo>:<x.y.z>-<config> -> each seeded image. A tag is moved by copying the manifest through the registry API (GET by
digest, PUT by tag), so it points at exactly the pushed digest; each tag is then read back and compared. Nothing is
moved unless every image of the run exists in the registry.

images.json: repository, run, base {image, version, created, products, windows_eval_expires, module_eval_ends},
configs {<name>: {image, tag, created}}, promoted (tag -> digest). Module evaluations end 45 days after the base
build (W4.4).

GitHub step outputs: images (path of images.json), base, and one <config> output per seeded image.
#>
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$SlsVersion,
    [Parameter(Mandatory)][string]$BaseImage,
    [string]$SeedDir = '',
    [string]$Configs = '',
    [bool]$Promote = $false,
    [string]$Out = 'images.json',
    [string]$Token = $(if ($env:REGISTRY_TOKEN) { $env:REGISTRY_TOKEN } else { $env:GITHUB_TOKEN })
)
$ErrorActionPreference = 'Stop'

$manifestTypes = 'application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json'

function Split-Ref([string]$Ref) {
    if ($Ref -notmatch '^ghcr\.io/(?<name>[^:@]+)@(?<digest>sha256:[0-9a-f]{64})$') { throw "expected ghcr.io/<owner>/<name>@sha256:<digest>, got '$Ref'" }
    [pscustomobject]@{ Name = $matches.name; Digest = $matches.digest }
}

$script:bearer = @{}
function Get-Bearer([string]$Name) {
    if (-not $script:bearer[$Name]) {
        $scope = if ($Promote) { 'pull,push' } else { 'pull' }
        $h = @{}
        if ($Token) {
            $owner = ($Name -split '/')[0]
            $h.Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${owner}:$Token")))"
        } elseif ($Promote) { throw 'no registry token (-Token, REGISTRY_TOKEN or GITHUB_TOKEN)' }
        $script:bearer[$Name] = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:${Name}:$scope" -Headers $h).token
    }
    $script:bearer[$Name]
}

function Get-Manifest([string]$Name, [string]$Reference) {
    $r = Invoke-WebRequest "https://ghcr.io/v2/$Name/manifests/$Reference" -SkipHttpErrorCheck -Headers @{
        Authorization = "Bearer $(Get-Bearer $Name)"; Accept = $manifestTypes }
    if ([int]$r.StatusCode -ne 200) { throw "GET manifest $Name/$Reference -> $($r.StatusCode): $($r.Content)" }
    $type = "$($r.Headers['Content-Type'])"
    $bytes = $r.RawContentStream.ToArray()
    [pscustomobject]@{ Bytes = $bytes; Type = $type; Digest = "$($r.Headers['Docker-Content-Digest'])"; Json = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -DateKind String }
}

function Get-Labels([string]$Name, $Manifest) {
    if ($Manifest.Json.manifests) {
        # Index (docker with the containerd image store pushes one): labels are in the linux/amd64 image manifest.
        $p = @($Manifest.Json.manifests | Where-Object { $_.platform.os -eq 'linux' -and $_.platform.architecture -eq 'amd64' })[0]
        if (-not $p) { throw "index $($Manifest.Digest) in $Name has no linux/amd64 manifest" }
        $Manifest = Get-Manifest $Name $p.digest
    }
    if (-not $Manifest.Json.config) { return @{} }
    # The blob URL redirects to storage; pwsh drops the Authorization header on the redirect.
    $blob = Invoke-WebRequest "https://ghcr.io/v2/$Name/blobs/$($Manifest.Json.config.digest)" -Headers @{ Authorization = "Bearer $(Get-Bearer $Name)" }
    $cfg = [Text.Encoding]::UTF8.GetString($blob.RawContentStream.ToArray()) | ConvertFrom-Json -DateKind String
    $l = @{}
    if ($cfg.config.Labels) { foreach ($p in $cfg.config.Labels.PSObject.Properties) { $l[$p.Name] = "$($p.Value)" } }
    $l
}

function Set-Tag([string]$Name, [string]$Tag, $Manifest) {
    $r = Invoke-WebRequest "https://ghcr.io/v2/$Name/manifests/$Tag" -Method Put -Body $Manifest.Bytes -SkipHttpErrorCheck -Headers @{
        Authorization = "Bearer $(Get-Bearer $Name)"; 'Content-Type' = $Manifest.Type }
    if ([int]$r.StatusCode -notin 200, 201) { throw "PUT manifest ghcr.io/${Name}:$Tag -> $($r.StatusCode): $($r.Content)" }
    $back = Get-Manifest $Name $Tag
    if ($back.Digest -ne $Manifest.Digest) { throw "ghcr.io/${Name}:$Tag points at $($back.Digest), expected $($Manifest.Digest)" }
    Write-Host "ghcr.io/${Name}:$Tag -> $($Manifest.Digest)"
}

function Write-CiOutput([Collections.IDictionary]$Values) {
    if (-not $env:GITHUB_OUTPUT) { return }
    foreach ($k in $Values.Keys) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$k=$($Values[$k])" -Encoding utf8 }
}

$repoName = $Repository -replace '^ghcr\.io/', ''
$base = Split-Ref $BaseImage
if ($base.Name -ne $repoName) { throw "base image $BaseImage is not in $Repository" }
$baseManifest = Get-Manifest $base.Name $base.Digest
if ($baseManifest.Digest -ne $base.Digest) { throw "registry returned $($baseManifest.Digest) for $BaseImage" }
$labels = Get-Labels $base.Name $baseManifest
$version = $labels['org.opencontainers.image.version']
if ($version -notmatch '^\d+\.\d+\.\d+') { throw "base image $BaseImage has no usable org.opencontainers.image.version label ('$version')" }
$xyz = ([regex]::Match($version, '^\d+\.\d+\.\d+')).Value
$created = $labels['org.opencontainers.image.created']
$moduleEnds = if ($created) { ([datetime]::Parse($created, [Globalization.CultureInfo]::InvariantCulture, 'AdjustToUniversal')).AddDays(45).ToString('yyyy-MM-dd') } else { '' }

$images = [ordered]@{
    repository = $Repository
    run        = if ($env:GITHUB_RUN_ID) { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" } else { '' }
    base       = [ordered]@{
        image = $BaseImage; version = $version; created = $created; products = $labels['com.ni.sls.products']
        windows_eval_expires = $labels['com.ni.sls.windows-eval-expires']; module_eval_ends = $moduleEnds
    }
    configs    = [ordered]@{}
    promoted   = [ordered]@{}
}

$names = @($Configs -split '[,\s]+' | Where-Object { $_ })
$seeds = [ordered]@{}
foreach ($n in $names) {
    $f = if ($SeedDir) { Join-Path $SeedDir "image-$n.json" } else { '' }
    if (-not $f -or -not (Test-Path $f)) { throw "no seeded image record for $n ($f)" }
    $s = Get-Content $f -Raw | ConvertFrom-Json -DateKind String
    $ref = Split-Ref $s.image
    if ($ref.Name -ne $repoName) { throw "seeded image $($s.image) is not in $Repository" }
    $m = Get-Manifest $ref.Name $ref.Digest
    $cl = Get-Labels $ref.Name $m
    if ($cl['org.opencontainers.image.version'] -ne $version) { throw "seeded image $n has version '$($cl['org.opencontainers.image.version'])', base has '$version'" }
    $seeds[$n] = $m
    $images.configs[$n] = [ordered]@{ image = $s.image; tag = $s.tag; created = $cl['com.ni.sls.config-created']; minutes = $s.minutes; attempts = $s.attempts; host_cpu = $s.host_cpu }
}

if ($Promote) {
    $moves = [ordered]@{ $SlsVersion = $baseManifest; $xyz = $baseManifest }
    foreach ($n in $seeds.Keys) { $moves["$SlsVersion-$n"] = $seeds[$n]; $moves["$xyz-$n"] = $seeds[$n] }
    foreach ($t in $moves.Keys) {
        Set-Tag $repoName $t $moves[$t]
        $images.promoted["${Repository}:$t"] = $moves[$t].Digest
    }
}

$images | ConvertTo-Json -Depth 5 | Set-Content $Out -Encoding utf8
$o = [ordered]@{ images = (Resolve-Path $Out).Path; base = $BaseImage }
foreach ($n in $images.configs.Keys) { $o[$n] = $images.configs[$n].image }
Write-CiOutput $o

$md = @('### SystemLink Server images', '', '| image | digest reference | tag |', '|---|---|---|')
$md += "| base | ``$BaseImage`` | |"
foreach ($n in $images.configs.Keys) { $md += "| $n | ``$($images.configs[$n].image)`` | ``$($images.configs[$n].tag)`` |" }
$md += '', "SystemLink Server $version, built $created. Products: $($images.base.products)", ''
$md += "Windows evaluation expires $($images.base.windows_eval_expires); SystemLink module evaluations end $moduleEnds (45 days after the build; module UI pages are disabled after that).", ''
if ($Promote) {
    $md += '| floating tag | digest |', '|---|---|'
    foreach ($t in $images.promoted.Keys) { $md += "| ``$t`` | ``$($images.promoted[$t])`` |" }
} else { $md += 'Floating tags not moved (`promote: false`).' }
if ($env:GITHUB_STEP_SUMMARY) { $md -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
$md -join "`n" | Write-Host
