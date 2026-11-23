# Migration configuration seed: the data described in manifest.json (sls-test docs/workflow-test-plan.md W5.3).
#   pwsh build/New-SlsConfigImage.ps1 -BaseImage sls-server-mod:26.5 -Name migration -Seed configs/migration/Seed.ps1
# Contract: without -Verify create the data (on a server that has none of it); with -Verify throw when any of it is
# missing or a relationship is wrong (result -> product/files/steps, state -> feed/package, asset -> calibrations).
param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][string]$Container,
    [switch]$Verify, [string]$Manifest = (Join-Path $PSScriptRoot 'manifest.json'))
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Get-SlsServer -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\testkit\SlsTestKit.psm1')
}
$server = Get-SlsServer -Name $Container -Credential $Credential
$m = Get-Content $Manifest -Raw | ConvertFrom-Json -AsHashtable
$ws = @{}

# ConvertFrom-Json turns ISO strings into UTC DateTime values; strings are parsed as UTC.
function Utc($v) { if ($v -is [datetime]) { $v.ToUniversalTime() } else { [datetime]::Parse("$v", [cultureinfo]::InvariantCulture, 'AssumeUniversal,AdjustToUniversal') } }
function Iso($v) { (Utc $v).ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Api([string]$Path, [string]$Method = 'GET', $Body = $null) { Invoke-WorkspaceRetry { Invoke-SlsApi $server $Path -Method $Method -Body $Body } }
# Services learn about new workspaces asynchronously: for a short while they answer Skyline.UnknownWorkspace (the asset
# service: UserDoesNotHaveCreatePrivilegeInWorkspace, even for the admin).
# Multipart calls rebuild their content inside the script block because each send disposes it.
function Invoke-WorkspaceRetry([scriptblock]$Call, [int]$TimeoutSec = 180) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { return & $Call }
        catch {
            if ($_.Exception.Message -notmatch '(?i)UnknownWorkspace|workspace.{0,80}(does not exist|not found|unknown)|WorkspaceNotFound|DoesNotHave\w*PrivilegeInWorkspace' -or $sw.Elapsed.TotalSeconds -ge $TimeoutSec) { throw }
            Start-Sleep -Seconds 3
        }
    }
}
# Bulk create endpoints (Test Monitor, assets) answer 200 with a `failed` list and an `error` instead of an HTTP error,
# for example while the service doesn't know a new workspace yet; turn that into an exception the retry above sees.
# -Count 0: any number created (nested steps).
function New-Bulk([string]$Path, [string]$Key, $Body, [int]$Count = 1) {
    Invoke-WorkspaceRetry {
        $r = Invoke-SlsApi $server $Path -Method POST -Body $Body
        $created = @($r.$Key | Where-Object { $_ })
        if (@($r.failed | Where-Object { $_ }).Count -or -not $created.Count -or ($Count -gt 0 -and $created.Count -ne $Count)) {
            throw "POST $Path created $($created.Count) of $Count $Key`: $(ConvertTo-Json -InputObject $r.error -Depth 8 -Compress)"
        }
        , $created
    }
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "migration seed verify: $Message" } }
function Get-Workspaces { $h = @{}; foreach ($w in (Api 'niuser/v1/workspaces?take=1000').workspaces) { $h[$w.name] = $w.id }; $h }
function Get-Users { @((Api 'niuser/v1/users/query' POST @{ take = 1000 }).users) }
function Get-MigFiles { @((Api 'nifile/v1/service-groups/Default/files?take=1000').availableFiles | Where-Object { "$($_.properties.Name)" -like 'mig-*' }) }
function Get-RepoJob([string]$Id) {
    # Finished repo jobs answer 303 (redirect to the resource) with the job in the body.
    $job = $null
    Wait-SlsCondition { $script:repoJob = (Invoke-SlsApi $server "nirepo/v1/jobs/$Id" -PassThru).Json.job; $script:repoJob.status -in 'SUCCEEDED', 'FAILED' } `
        -TimeoutSec 180 -IntervalMs 1000 -Message "repo job $Id" | Out-Null
    $job = $script:repoJob
    if ($job.status -ne 'SUCCEEDED') { throw "repo job $Id ($($job.operation)) $($job.status): $($job | ConvertTo-Json -Compress -Depth 5)" }
    $job
}
function Get-TemplateSteps([string]$Name) {
    $all = [Collections.Generic.List[object]]::new()
    function Walk($steps, [string]$parent) { foreach ($st in $steps) { $all.Add(@{ stepId = $st.stepId; parentId = $parent; step = $st }); if ($st.children) { Walk $st.children $st.stepId } } }
    Walk $m.stepTemplates[$Name] 'root'
    $all
}

# Services lag the healthcheck; the tag and repo services can answer 500/503 for a while after authentication works.
Test-SlsServiceCoverage $server -WaitSec 300 -Throw | Out-Null
Wait-SlsCondition { try { Invoke-SlsApi $server 'nitag/v2/tags?take=1' | Out-Null; $true } catch { $false } } -TimeoutSec 180 -IntervalMs 3000 `
    -Message 'tag service' | Out-Null

if ($Verify) {
    $ws = Get-Workspaces
    foreach ($w in $m.workspaces) { Assert ($ws.ContainsKey($w)) "workspace $w missing" }

    $users = Get-Users
    foreach ($u in $m.users) {
        $x = $users | Where-Object login -eq $u.login
        Assert ($null -ne $x) "user $($u.login) missing"
        Assert ($x.email -eq $u.email -and $x.properties.team -eq $u.properties.team) "user $($u.login) fields differ"
    }

    $files = Get-MigFiles
    Assert ($files.Count -eq $m.files.Count) "expected $($m.files.Count) mig files, found $($files.Count)"
    $fileIds = @{}
    foreach ($f in $m.files) {
        $x = $files | Where-Object { $_.properties.Name -eq $f.name }
        Assert ($null -ne $x) "file $($f.name) missing"
        Assert ($x.workspace -eq $ws[$f.workspace]) "file $($f.name) not in $($f.workspace)"
        foreach ($k in $f.properties.Keys) { Assert ($x.properties.$k -eq $f.properties[$k]) "file $($f.name) property $k" }
        $fileIds[$f.name] = $x.id
    }

    $products = @((Api 'nitestmonitor/v2/query-products' POST @{ take = 1000; filter = 'family == "mig-family"' }).products)
    Assert ($products.Count -eq $m.products.Count) "expected $($m.products.Count) products, found $($products.Count)"
    foreach ($p in $m.products) {
        $x = $products | Where-Object partNumber -eq $p.partNumber
        Assert ($null -ne $x) "product $($p.partNumber) missing"
        foreach ($k in $p.properties.Keys) { Assert ($x.properties.$k -eq $p.properties[$k]) "product $($p.partNumber) property $k" }
    }

    $results = @((Api 'nitestmonitor/v2/query-results' POST @{ take = 1000; filter = "programName == `"$($m.resultDefaults.programName)`"" }).results)
    Assert ($results.Count -eq $m.results.Count) "expected $($m.results.Count) results, found $($results.Count)"
    $stepCount = 0
    foreach ($r in $m.results) {
        $x = $results | Where-Object serialNumber -eq $r.serialNumber
        Assert ($null -ne $x) "result $($r.serialNumber) missing"
        Assert ($x.partNumber -eq $r.partNumber -and ($products.partNumber -contains $x.partNumber)) "result $($r.serialNumber) product"
        Assert ($x.workspace -eq $ws[$r.workspace]) "result $($r.serialNumber) workspace"
        Assert ($x.status.statusType -eq $r.status) "result $($r.serialNumber) status $($x.status.statusType) != $($r.status)"
        if ($r.statusName) { Assert ($x.status.statusName -eq $r.statusName) "result $($r.serialNumber) statusName" }
        $want = @($r.files | Where-Object { $_ } | ForEach-Object { $fileIds[$_] } | Sort-Object)
        $have = @($x.fileIds | Where-Object { $_ } | Sort-Object)
        Assert (($want -join ',') -eq ($have -join ',')) "result $($r.serialNumber) fileIds [$($have -join ',')] != [$($want -join ',')]"
        $steps = @((Api 'nitestmonitor/v2/query-steps' POST @{ take = 100; filter = "resultId == `"$($x.id)`"" }).steps)
        $expected = Get-TemplateSteps $r.steps
        Assert ($steps.Count -eq $expected.Count) "result $($r.serialNumber) has $($steps.Count) steps, expected $($expected.Count)"
        foreach ($e in $expected) {
            $s = $steps | Where-Object stepId -eq $e.stepId
            Assert ($null -ne $s -and $s.parentId -eq $e.parentId) "result $($r.serialNumber) step $($e.stepId) parent"
            if ($e.step.inputs) { Assert (@($s.inputs).Count -eq $e.step.inputs.Count) "result $($r.serialNumber) step $($e.stepId) inputs" }
            if ($e.step.measurement) { Assert (@($s.data.parameters).Count -eq 1) "result $($r.serialNumber) step $($e.stepId) measurement" }
        }
        $stepCount += $steps.Count
    }

    $feeds = @((Api 'nirepo/v1/feeds').feeds)
    $feedById = @{}
    foreach ($f in $m.feeds) {
        $x = $feeds | Where-Object name -eq $f.name
        Assert ($null -ne $x) "feed $($f.name) missing"
        Assert ($x.workspace -eq $ws[$f.workspace]) "feed $($f.name) workspace"
        $pkgs = @((Api "nirepo/v1/feeds/$($x.id)/packages").packages)
        foreach ($p in $f.packages) {
            Assert ($null -ne ($pkgs | Where-Object { $_.metadata.packageName -eq $p.name -and $_.metadata.version -eq $p.version })) "feed $($f.name) package $($p.name) $($p.version)"
        }
        $feedById[$f.name] = $x
    }

    $assets = @((Api 'niapm/v1/query-assets' POST @{ take = 1000 }).assets)
    foreach ($a in $m.assets) {
        $x = $assets | Where-Object name -eq $a.name
        Assert ($null -ne $x) "asset $($a.name) missing"
        Assert ($x.workspace -eq $ws[$a.workspace]) "asset $($a.name) workspace"
        $hist = @((Api "niapm/v1/assets/$($x.id)/history/calibration?take=100").calibrationHistory)
        Assert ($hist.Count -eq $a.calibrations.Count) "asset $($a.name) has $($hist.Count) calibrations, expected $($a.calibrations.Count)"
        foreach ($c in $a.calibrations) {
            $op = if ($c.operatorUser) { $u = $users | Where-Object login -eq $c.operatorUser; "$($u.firstName) $($u.lastName)" } else { $c.operator }
            Assert ($null -ne ($hist | Where-Object { (Iso $_.date) -eq (Iso $c.date) -and $_.operator.displayName -eq $op })) "asset $($a.name) calibration $($c.date) by $op"
        }
    }

    $stateList = @((Api 'nisystemsstate/v1/states?take=1000').states)
    foreach ($st in $m.states) {
        $x = $stateList | Where-Object name -eq $st.name
        Assert ($null -ne $x) "state $($st.name) missing"
        Assert ($x.workspace -eq $ws[$st.workspace]) "state $($st.name) workspace"
        $full = Api "nisystemsstate/v1/states/$($x.id)"
        $feed = $feedById[$st.feed]
        Assert ($null -ne ($full.feeds | Where-Object { $_.name -eq $st.feed -and $_.url -like "*$($feed.directoryUri)" })) "state $($st.name) feed $($st.feed)"
        foreach ($p in $st.packages) { Assert ($null -ne ($full.packages | Where-Object { $_.name -eq $p.name -and $_.version -eq $p.version })) "state $($st.name) package $($p.name)" }
    }

    foreach ($t in $m.outOfScope.tags) {
        $v = Api "nitag/v2/tags/$($t.path)/values/current"
        Assert ("$($v.value.value)" -eq $t.value) "tag $($t.path) = '$($v.value.value)', expected '$($t.value)'"
    }
    foreach ($al in $m.outOfScope.alarms) {
        $q = Api 'nialarm/v1/query-instances' POST @{ take = 10; alarmId = $al.alarmId; workspaces = @($ws[$al.workspace]) }
        Assert ($q.totalCount -ge 1) "alarm $($al.alarmId) missing"
    }
    foreach ($d in $m.outOfScope.userData) {
        $q = Api 'niuserdata/v1/query-items' POST @{ take = 10; filter = "application == `"$($d.application)`" && name == `"$($d.name)`"" }
        Assert (@($q.items).Count -ge 1) "user data $($d.application)/$($d.name) missing"
    }
    Write-Host (("migration data present: {0} workspaces, {1} users, {2} files, {3} products, {4} results, {5} steps, {6} feeds, {7} assets, {8} states; " +
        "out of scope: {9} tags, {10} alarms, {11} user data") -f $m.workspaces.Count, $m.users.Count, $files.Count, $products.Count, $results.Count, $stepCount,
        $m.feeds.Count, $m.assets.Count, $m.states.Count, $m.outOfScope.tags.Count, $m.outOfScope.alarms.Count, $m.outOfScope.userData.Count)
    return
}

$ws = Get-Workspaces
if ($ws.ContainsKey($m.workspaces[0])) { throw "workspace $($m.workspaces[0]) already exists; seed a fresh server" }
foreach ($w in $m.workspaces) { $ws[$w] = (Api 'niuser/v1/workspaces' POST @{ name = $w }).id }

$userIds = @{}; $userNames = @{}
foreach ($u in $m.users) {
    $x = Api 'niuser/v1/users' POST @{ firstName = $u.firstName; lastName = $u.lastName; email = $u.email; login = $u.login; niuaId = $u.login
        acceptedToS = $true; keywords = $u.keywords; properties = $u.properties }
    $userIds[$u.login] = $x.id; $userNames[$u.login] = "$($u.firstName) $($u.lastName)"
}

$fileIds = @{}
foreach ($f in $m.files) {
    $text = (1..$f.lines | ForEach-Object { "$($f.name) line $_" }) -join "`n"
    $meta = @{ Name = $f.name }
    foreach ($k in $f.properties.Keys) { $meta[$k] = $f.properties[$k] }
    $x = Invoke-WorkspaceRetry {
        $mp = [Net.Http.MultipartFormDataContent]::new()
        $fc = [Net.Http.ByteArrayContent]::new([Text.Encoding]::ASCII.GetBytes($text))
        $fc.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('text/plain')
        $mp.Add($fc, 'file', $f.name)
        $mp.Add([Net.Http.StringContent]::new(($meta | ConvertTo-Json -Compress)), 'metadata')
        Invoke-SlsApi $server "nifile/v1/service-groups/Default/upload-files?workspace=$($ws[$f.workspace])" -Method POST -Content $mp
    }
    $fileIds[$f.name] = ($x.uri -split '/')[-1]
}

New-Bulk 'nitestmonitor/v2/products' products -Count $m.products.Count @{ products = @($m.products | ForEach-Object { @{ partNumber = $_.partNumber; name = $_.name; family = $_.family
                keywords = $_.keywords; properties = $_.properties } }) } | Out-Null

function New-StepRequest($st, [string]$resultId, $status, [bool]$failed) {
    $req = @{ resultId = $resultId; stepId = $st.stepId; name = $st.name; stepType = $st.stepType; status = $status; totalTimeInSeconds = 0.5 }
    if ($st.inputs) { $req.inputs = @($st.inputs.Keys | ForEach-Object { @{ name = $_; value = $st.inputs[$_] } }) }
    if ($st.outputs) { $req.outputs = @($st.outputs.Keys | ForEach-Object { @{ name = $_; value = $st.outputs[$_] } }) }
    if ($st.measurement) {
        $ms = $st.measurement
        $req.data = @{ text = "$($ms.name) measured"; parameters = @(@{ name = $ms.name; measurement = "$($ms.value)"; lowLimit = "$($ms.low)"; highLimit = "$($ms.high)"
                    units = $ms.units; comparisonType = 'GELE'; status = $(if ($failed) { 'Failed' } else { 'Passed' }) }) }
    }
    if ($st.children) { $req.children = @($st.children | ForEach-Object { New-StepRequest $_ $resultId $status $failed }) }
    $req
}
$base = Utc $m.resultDefaults.startedAtBase
$i = 0
foreach ($r in $m.results) {
    $i++
    $status = @{ statusType = $r.status }; if ($r.statusName) { $status.statusName = $r.statusName }
    $res = @(New-Bulk 'nitestmonitor/v2/results' results @{ results = @(@{ programName = $m.resultDefaults.programName; status = $status; partNumber = $r.partNumber
                    serialNumber = $r.serialNumber; operator = $m.resultDefaults.operator; hostName = $m.resultDefaults.hostName; workspace = $ws[$r.workspace]
                    startedAt = $base.AddHours($i).ToString('yyyy-MM-ddTHH:mm:ssZ'); totalTimeInSeconds = 10 + $i; keywords = @('mig')
                    properties = @{ migKey = $r.serialNumber }; fileIds = @($r.files | Where-Object { $_ } | ForEach-Object { $fileIds[$_] }) }) })[0]
    $steps = @($m.stepTemplates[$r.steps] | ForEach-Object { New-StepRequest $_ $res.id $status ($r.status -eq 'FAILED') })
    New-Bulk 'nitestmonitor/v2/steps' steps -Count 0 @{ steps = $steps; updateResultTotalTime = $false } | Out-Null
}

# Hosted package: build a minimal .nipkg with nipkg pack in the guest, copy it out as base64, upload it to the pool and
# reference it from the feed.
$feeds = @{}
foreach ($f in $m.feeds) {
    $job = Get-RepoJob (Api 'nirepo/v1/feeds' POST @{ name = $f.name; description = $f.description; platform = 'WINDOWS'; workspace = $ws[$f.workspace] }).jobId
    $feeds[$f.name] = Api "nirepo/v1/feeds/$($job.resourceId)" | Select-Object -ExpandProperty feed
    foreach ($p in $f.packages) {
        $guest = @"
`$ErrorActionPreference = 'Stop'
`$nipkg = Join-Path `${env:ProgramFiles} 'National Instruments\NI Package Manager\nipkg.exe'
`$root = Join-Path `$env:TEMP 'mig-pkg'
Remove-Item `$root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "`$root\src\control", "`$root\src\data\documents\$($p.name)", "`$root\out" | Out-Null
[IO.File]::WriteAllText("`$root\src\debian-binary", "2.0``n")
[IO.File]::WriteAllText("`$root\src\control\control", "Package: $($p.name)``nVersion: $($p.version)``nArchitecture: windows_all``nMaintainer: SLS Test <sls-test@example.com>``nDescription: Migration test package``nXB-Plugin: file``nXB-UserVisible: yes``nXB-DisplayName: Migration Test Package``nXB-DisplayVersion: $($p.version)``n")
[IO.File]::WriteAllText("`$root\src\data\documents\$($p.name)\readme.txt", 'migration test package')
& `$nipkg pack "`$root\src" "`$root\out" | Out-Null
if (`$LASTEXITCODE) { throw "nipkg pack exit `$LASTEXITCODE" }
`$f = Get-ChildItem "`$root\out\*.nipkg" | Select-Object -First 1
'FILE=' + `$f.Name
'B64=' + [Convert]::ToBase64String([IO.File]::ReadAllBytes(`$f.FullName))
Remove-Item `$root -Recurse -Force
"@
        $out = (Invoke-SlsGuest $server $guest -TimeoutSec 300).Output
        $name = ($out | Where-Object { $_ -like 'FILE=*' }).Substring(5)
        $bytes = [Convert]::FromBase64String(($out | Where-Object { $_ -like 'B64=*' }).Substring(4))
        $mp = [Net.Http.MultipartFormDataContent]::new()
        $bc = [Net.Http.ByteArrayContent]::new($bytes)
        $bc.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $mp.Add($bc, $name, $name)
        $up = Invoke-SlsApi $server 'nirepo/v1/upload-packages?shouldOverwrite=true' -Method POST -Content $mp
        $pkgId = (Get-RepoJob $up.jobIds[0]).resourceId
        Get-RepoJob (Api "nirepo/v1/feeds/$($feeds[$f.name].id)/add-package-references" POST @{ packageReferences = @($pkgId) }).jobId | Out-Null
    }
}

foreach ($a in $m.assets) {
    $cals = @($a.calibrations | ForEach-Object {
            $op = if ($_.operatorUser) { @{ displayName = $userNames[$_.operatorUser]; userId = $userIds[$_.operatorUser] } } else { @{ displayName = $_.operator } }
            $d = Utc $_.date
            @{ date = $d.ToString('yyyy-MM-ddTHH:mm:ssZ'); recommendedInterval = 12; nextRecommendedDate = $d.AddMonths(12).ToString('yyyy-MM-ddTHH:mm:ssZ')
                comments = $_.comments; entryType = 'MANUAL'; operator = $op }
        })
    $x = @(New-Bulk 'niapm/v1/assets' assets @{ assets = @(@{ name = $a.name; modelName = $a.modelName; serialNumber = $a.serialNumber; vendorName = $a.vendorName
                    busType = $a.busType; assetType = 'GENERIC'; discoveryType = 'Manual'; workspace = $ws[$a.workspace]; supportsExternalCalibration = $true
                    location = @{ state = @{ assetPresence = 'PRESENT' } }; keywords = @('mig'); properties = @{ migKey = $a.serialNumber }
                    externalCalibration = $cals[0] }) })[0]
    foreach ($c in $cals | Select-Object -Skip 1) { Api "niapm/v1/assets/$($x.id)/history/calibration" POST @{ externalCalibration = $c } | Out-Null }
}

foreach ($st in $m.states) {
    $feedDef = $m.feeds | Where-Object name -eq $st.feed
    $feed = $feeds[$st.feed]
    Api 'nisystemsstate/v1/states' POST @{ name = $st.name; description = 'Migration test state'; distribution = 'WINDOWS'; architecture = 'X64'
        workspace = $ws[$st.workspace]; feeds = @(@{ name = $st.feed; url = "$($feedDef.stateUrlBase)$($feed.directoryUri)"; enabled = $true; compressed = $false })
        packages = @($st.packages | ForEach-Object { @{ name = $_.name; version = $_.version; installRecommends = $false } }) } | Out-Null
}

foreach ($t in $m.outOfScope.tags) {
    Api "nitag/v2/tags/$($t.path)" PUT @{ type = $t.type; path = $t.path; keywords = @('mig') } | Out-Null
    Api "nitag/v2/tags/$($t.path)/values/current" PUT @{ value = @{ type = $t.type; value = $t.value } } | Out-Null
}
foreach ($al in $m.outOfScope.alarms) {
    Api 'nialarm/v1/instances' POST @{ alarmId = $al.alarmId; workspace = $ws[$al.workspace]; createdBy = 'sls-test'; channel = $al.channel; resourceType = 'Tag'
        displayName = $al.displayName; keywords = @('mig'); transition = @{ transitionType = 'SET'; severityLevel = $al.severityLevel; condition = $al.condition
            shortText = $al.displayName; occurredAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } } | Out-Null
}
# The user data service expects a top-level JSON array.
$items = @($m.outOfScope.userData | ForEach-Object { @{ application = $_.application; category = $_.category; name = $_.name; value = $_.value; visibleToOthers = $true } })
Api 'niuserdata/v1/items' POST (ConvertTo-Json -InputObject $items -Depth 10 -Compress) | Out-Null

Write-Host "migration data created: $($m.workspaces.Count) workspaces, $($m.users.Count) users, $($m.files.Count) files, $($m.products.Count) products, $($m.results.Count) results, $($m.feeds.Count) feeds, $($m.assets.Count) assets, $($m.states.Count) states, plus out-of-scope tags/alarm/user data"
