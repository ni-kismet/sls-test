#Requires -Version 7.2
<#
.SYNOPSIS
Pushes a SystemLink Server image to ghcr.io with retries.

.DESCRIPTION
Every tag (the image's own tag plus -Tag) is pushed with up to -Retries attempts (60 s, 120 s, ... backoff). Then the
registry digest is read and the package visibility reported (ghcr.io pull token without credentials: 200 = public).
The first push to a new package creates it; from a public repository's GITHUB_TOKEN the new package is public.

GitHub step outputs: digest (<repo>@sha256:...), tags (comma separated full references), public (true/false), push_sec.

.EXAMPLE
pwsh src/ci/Push-SlsImage.ps1 -Image ghcr.io/ni-kismet/sls-server:26.5 -Tag 26.5-r12
#>
param(
    [Parameter(Mandatory)][string]$Image,
    [string[]]$Tag = @(),
    [int]$Retries = 3
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
if ($public) { Write-Host "$repo is public (anonymous pull allowed)" } else { Write-Host "$repo is private (anonymous pull denied: $($anon.StatusCode))" }

Write-Host "pushed $digest ($($refs -join ', ')) in $pushSec s"
Write-CiOutput ([ordered]@{ digest = $digest; tags = $refs -join ','; public = "$public".ToLowerInvariant(); push_sec = $pushSec })
