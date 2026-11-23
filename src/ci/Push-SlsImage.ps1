#Requires -Version 7.2
<#
.SYNOPSIS
Pushes a SystemLink Server image to ghcr.io with retries, guarding against creating a new (and, from a public
repository, PUBLIC) package by accident.

.DESCRIPTION
Push guard (unless -SkipGuard): before pushing, the package is looked up with the GitHub packages API
(GET /users|orgs/<owner>/packages/container/<name>) and, when that doesn't find it (tokens without packages access
also get 404), with the registry (tags/list: 404 NAME_UNKNOWN = missing). A missing package fails unless
-AllowNewPackage: the first push from a public repository's GITHUB_TOKEN creates a PUBLIC package, and images built
with a fixed admin password or a license must not become public by accident.

Every tag (the image's own tag plus -Tag) is pushed with up to -Retries attempts (60 s, 120 s, ... backoff). Then the
registry digest is read and the package visibility checked anonymously (ghcr.io pull token without credentials:
200 = public).

GitHub step outputs: digest (<repo>@sha256:...), tags (comma separated full references), public (true/false),
new_package (true/false), push_sec.

.EXAMPLE
pwsh scripts/Push-SlsImage.ps1 -Image ghcr.io/rajsite/sls-server:26.5 -Tag 26.5-r12 -AllowNewPackage
#>
param(
    [Parameter(Mandatory)][string]$Image,
    [string[]]$Tag = @(),
    [int]$Retries = 3,
    [string]$Token = $(if ($env:REGISTRY_TOKEN) { $env:REGISTRY_TOKEN } else { $env:GITHUB_TOKEN }),
    [switch]$AllowNewPackage,
    [switch]$SkipGuard
)
$ErrorActionPreference = 'Stop'

function Write-CiOutput([Collections.IDictionary]$Values) {
    if (-not $env:GITHUB_OUTPUT) { return }
    foreach ($k in $Values.Keys) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$k=$($Values[$k])" -Encoding utf8 }
}

if ($Image -notmatch '^ghcr\.io/(?<owner>[^/]+)/(?<name>[^:@]+):(?<tag>[^:@/]+)$') {
    throw "Image must be ghcr.io/<owner>/<name>:<tag> (got '$Image')"
}
$owner = $matches.owner.ToLowerInvariant(); $name = $matches.name; $repo = "ghcr.io/$owner/$name"
& docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) { throw "image $Image does not exist locally" }

$refs = [Collections.Generic.List[string]]::new(); $refs.Add($Image)
foreach ($t in $Tag | Where-Object { $_ -and $_.Trim() }) {
    $t = $t.Trim()
    $ref = if ($t.Contains(':')) { $t } else { "${repo}:$t" }
    if (-not $ref.StartsWith("${repo}:")) { throw "tag $ref is not in $repo" }
    if ($refs -notcontains $ref) {
        & docker tag $Image $ref
        if ($LASTEXITCODE -ne 0) { throw "docker tag $Image $ref failed" }
        $refs.Add($ref)
    }
}

$newPackage = $false
if (-not $SkipGuard) {
    if (-not $Token) { throw 'push guard: no token (-Token, REGISTRY_TOKEN or GITHUB_TOKEN); use -SkipGuard to push unguarded' }
    $api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
    $h = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $ownerType = (Invoke-RestMethod "$api/users/$owner" -Headers $h).type
    $scope = if ($ownerType -eq 'Organization') { 'orgs' } else { 'users' }
    $url = "$api/$scope/$owner/packages/container/$([uri]::EscapeDataString($name))"
    $r = Invoke-WebRequest $url -Headers $h -SkipHttpErrorCheck
    $exists = $null
    if ([int]$r.StatusCode -eq 200) {
        $exists = $true
        Write-Host "push guard: package $owner/$name exists ($((($r.Content | ConvertFrom-Json).visibility)))"
    } else {
        # The packages API also answers 404 for tokens without packages access; ask the registry before deciding.
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${owner}:$Token"))
        $tk = Invoke-WebRequest "https://ghcr.io/token?scope=repository:${owner}/${name}:pull" -Headers @{ Authorization = "Basic $basic" } -SkipHttpErrorCheck
        if ([int]$tk.StatusCode -eq 200) {
            $bearer = ($tk.Content | ConvertFrom-Json).token
            $tl = Invoke-WebRequest "https://ghcr.io/v2/$owner/$name/tags/list" -Headers @{ Authorization = "Bearer $bearer" } -SkipHttpErrorCheck
            if ([int]$tl.StatusCode -eq 200) { $exists = $true; Write-Host "push guard: package $owner/$name exists (registry)" }
            elseif ([int]$tl.StatusCode -eq 404 -and $tl.Content -match 'NAME_UNKNOWN') { $exists = $false }
        }
        if ($null -eq $exists) { throw "push guard: can't tell whether $owner/$name exists (API $($r.StatusCode), registry token $($tk.StatusCode)$(if ($tl) { ", tags $($tl.StatusCode)" }))" }
    }
    if (-not $exists) {
        if (-not $AllowNewPackage) {
            throw "push guard: package $owner/$name does not exist; the first push would create it (PUBLIC when pushed from a public repository's GITHUB_TOKEN). Create it as private first, or pass -AllowNewPackage."
        }
        Write-Host "::warning::push guard: creating new package $owner/$name (-AllowNewPackage)"
        $newPackage = $true
    }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($ref in $refs) {
    for ($i = 1; ; $i++) {
        Write-Host "docker push $ref (attempt $i of $Retries)"
        & docker push $ref
        if ($LASTEXITCODE -eq 0) { break }
        if ($i -ge $Retries) { throw "docker push $ref failed $Retries times" }
        Start-Sleep -Seconds (60 * $i)
    }
}
$pushSec = [math]::Round($sw.Elapsed.TotalSeconds)
$digest = @(& docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' $Image) | Where-Object { $_ -like "$repo@*" } | Select-Object -First 1

$anon = Invoke-WebRequest "https://ghcr.io/token?scope=repository:${owner}/${name}:pull" -SkipHttpErrorCheck
$public = [int]$anon.StatusCode -eq 200
if ($public) { Write-Host "::warning::$repo is PUBLIC (anonymous pull allowed)" } else { Write-Host "$repo is private (anonymous pull denied: $($anon.StatusCode))" }

Write-Host "pushed $digest ($($refs -join ', ')) in $pushSec s"
Write-CiOutput ([ordered]@{ digest = $digest; tags = $refs -join ','; public = "$public".ToLowerInvariant(); new_package = "$newPackage".ToLowerInvariant(); push_sec = $pushSec })
