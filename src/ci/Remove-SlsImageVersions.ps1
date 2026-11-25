#Requires -Version 7.2
<#
.SYNOPSIS
Deletes old versions of a ghcr.io image package. Dry run unless -Delete.

.DESCRIPTION
Deletes every package version created more than -OlderThanDays days ago (0: every version), except:
- versions with a floating tag: any tag that is not an immutable build tag (r<run>[-<config>],
  <x.y.z>-<yyyyMMdd>[-<HHmm>][-<config>]), so <sls-version>[-<config>] and <x.y.z>[-<config>] always stay;
- manifests that a kept version lists. Docker with the containerd image store pushes an index whose image and
  attestation manifests are separate, untagged package versions; deleting those breaks the tagged image.
Tagged versions are deleted before untagged ones. Layers shared with kept images stay: the registry keeps every blob a
remaining manifest references. Deleted versions can be restored from the package settings for 30 days. GitHub refuses
to delete a version of a public package with more than 5,000 downloads; such failures are reported and the rest
continues.

Token: -Token, else GH_TOKEN or GITHUB_TOKEN, else `gh auth token`. Listing needs read:packages; deleting needs admin
on the package. A personal token needs the read:packages and delete:packages scopes
(gh auth refresh -s read:packages,delete:packages). A workflow's GITHUB_TOKEN needs packages: write, and the
repository needs the Admin role under the package's Manage Actions access (the repository whose workflow first pushed
the package has it).

Writes a table of every version (keep or delete, and why) to the console and the job summary. Exits 1 when a delete
failed.

.EXAMPLE
pwsh src/ci/Remove-SlsImageVersions.ps1 -Repository ghcr.io/ni-kismet/sls-server-actions-test
.EXAMPLE
pwsh src/ci/Remove-SlsImageVersions.ps1 -Repository ghcr.io/ni-kismet/sls-server -OlderThanDays 45 -Delete
#>
param(
    [Parameter(Mandatory)][string]$Repository,
    [ValidateRange(0, 3650)][int]$OlderThanDays = 45,
    [switch]$Delete,
    [string]$Token = ''
)
$ErrorActionPreference = 'Stop'

$immutableTag = '^(r\d+|\d+\.\d+\.\d+-\d{8}(-\d{4})?)(-[a-z0-9][a-z0-9_.-]*)?$'
$manifestTypes = 'application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json'

if ($Repository -notmatch '^ghcr\.io/(?<owner>[^/]+)/(?<name>[^:@]+)$') { throw "Repository must be ghcr.io/<owner>/<name> (got '$Repository')" }
$owner = $matches.owner.ToLowerInvariant(); $name = $matches.name
if (-not $Token) { $Token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { "$(& gh auth token 2>$null)".Trim() } }
if (-not $Token) { throw 'no token: pass -Token, set GH_TOKEN or GITHUB_TOKEN, or log in with gh' }

$api = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' }
$h = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$ownerType = (Invoke-RestMethod "$api/users/$owner" -Headers $h).type
$scope = if ($ownerType -eq 'Organization') { "orgs/$owner" } else { "users/$owner" }
$pkg = "$api/$scope/packages/container/$([uri]::EscapeDataString($name))"

$versions = [Collections.Generic.List[object]]::new()
for ($page = 1; ; $page++) {
    $r = Invoke-WebRequest "$pkg/versions?per_page=100&page=$page" -Headers $h -SkipHttpErrorCheck
    if ([int]$r.StatusCode -ne 200) { throw "GET $pkg/versions -> $($r.StatusCode): $($r.Content)" }
    $batch = @($r.Content | ConvertFrom-Json -DateKind String)
    foreach ($v in $batch) {
        $versions.Add([pscustomobject]@{
                Id      = $v.id
                Digest  = $v.name
                Created = [DateTimeOffset]::Parse($v.created_at, [Globalization.CultureInfo]::InvariantCulture)
                Tags    = @($v.metadata.container.tags | Where-Object { $_ })
                Action  = ''
                Reason  = ''
            })
    }
    if ($batch.Count -lt 100) { break }
}
if (-not $versions.Count) { Write-Host "$Repository has no versions"; return }

$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${owner}:$Token"))
$t = Invoke-WebRequest "https://ghcr.io/token?scope=repository:${owner}/${name}:pull" -Headers @{ Authorization = "Basic $basic" } -SkipHttpErrorCheck
# A token ghcr.io doesn't accept can still read a public package anonymously.
if ([int]$t.StatusCode -ne 200) { $t = Invoke-WebRequest "https://ghcr.io/token?scope=repository:${owner}/${name}:pull" -SkipHttpErrorCheck }
if ([int]$t.StatusCode -ne 200) { throw "no ghcr.io pull token for $Repository ($($t.StatusCode))" }
$bearer = ($t.Content | ConvertFrom-Json).token
function Get-ChildDigest([string]$Digest) {
    $r = Invoke-WebRequest "https://ghcr.io/v2/$owner/$name/manifests/$Digest" -SkipHttpErrorCheck -Headers @{ Authorization = "Bearer $bearer"; Accept = $manifestTypes }
    if ([int]$r.StatusCode -ne 200) { throw "GET manifest $Repository@$Digest -> $($r.StatusCode)" }
    $m = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
    @($m.manifests | ForEach-Object { $_.digest })
}

$cutoff = [DateTimeOffset]::UtcNow.AddDays(-$OlderThanDays)
foreach ($v in $versions | Where-Object { $_.Tags }) {
    $floating = @($v.Tags | Where-Object { $_ -notmatch $immutableTag })
    if ($floating) { $v.Action = 'keep'; $v.Reason = "floating tag $($floating -join ', ')" }
    elseif ($v.Created -ge $cutoff) { $v.Action = 'keep'; $v.Reason = "newer than $OlderThanDays days" }
}
# Untagged versions are mostly the manifests a tagged index lists: keep those of kept versions, whatever their age.
$byDigest = @{}; foreach ($v in $versions) { $byDigest[$v.Digest] = $v }
foreach ($v in @($versions | Where-Object { $_.Action -eq 'keep' })) {
    foreach ($d in Get-ChildDigest $v.Digest) {
        $c = $byDigest[$d]
        if ($c -and -not $c.Tags -and $c.Action -ne 'keep') { $c.Action = 'keep'; $c.Reason = "listed by $($v.Digest.Substring(0, 19)) ($($v.Tags[0]))" }
    }
}
foreach ($v in $versions | Where-Object { -not $_.Action }) {
    if ($v.Created -ge $cutoff) { $v.Action = 'keep'; $v.Reason = "newer than $OlderThanDays days" }
    else { $v.Action = 'delete'; $v.Reason = if ($v.Tags) { "older than $OlderThanDays days" } else { "untagged, older than $OlderThanDays days, not listed by a kept version" } }
}

$doomed = @($versions | Where-Object Action -eq 'delete' | Sort-Object { -not $_.Tags.Count }, Created)
if ($doomed.Count -eq $versions.Count) { throw "refusing to delete every version of $Repository (no floating tag and nothing newer than $OlderThanDays days)" }

$failed = 0
if ($Delete) {
    foreach ($v in $doomed) {
        $r = Invoke-WebRequest "$pkg/versions/$($v.Id)" -Method Delete -Headers $h -SkipHttpErrorCheck
        if ([int]$r.StatusCode -eq 204) { $v.Action = 'deleted' }
        else { $failed++; $v.Action = 'FAILED'; $v.Reason += "; DELETE -> $($r.StatusCode): $(($r.Content | ConvertFrom-Json -ErrorAction SilentlyContinue).message)" }
    }
}

$verb = if ($Delete) { 'Deleted' } else { 'Dry run: would delete' }
$summary = "$verb $(@($doomed | Where-Object Action -ne 'FAILED').Count) of $($versions.Count) versions of $Repository older than $OlderThanDays days (before $($cutoff.ToString('yyyy-MM-dd'))); $failed failed."
$md = @("### Image cleanup: $Repository", '', $summary, '', '| action | created | tags | digest | reason |', '|---|---|---|---|---|')
foreach ($v in $versions | Sort-Object Created -Descending) {
    $md += "| $($v.Action) | $($v.Created.UtcDateTime.ToString('yyyy-MM-dd HH:mm')) | $($v.Tags -join ', ') | ``$($v.Digest.Substring(0, 19))`` | $($v.Reason) |"
}
$md -join "`n" | Write-Host
if ($env:GITHUB_STEP_SUMMARY) { $md -join "`n" | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ($failed) { Write-Host "::error::$failed version(s) of $Repository could not be deleted"; exit 1 }
