# Demo configuration seed (the Spike 1 demo data): 100 DOUBLE tags demo.line<1..10>.sensor<001..100> with value
# <i>.25 and one text file in the file service.
#   pwsh src/build/New-SlsConfigImage.ps1 -BaseImage sls-server:26.5 -Name demo -Seed src/seeds/demo/Seed.ps1
# Contract: without -Verify create the data; with -Verify throw when it is missing.
param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][string]$Container,
    [switch]$Verify)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Get-SlsServer -ErrorAction SilentlyContinue)) {
    Import-Module $(if ($env:SLS_TESTKIT) { $env:SLS_TESTKIT } else { Join-Path $PSScriptRoot '..\..\testkit\SlsTestKit.psm1' })
}
$server = Get-SlsServer -Name $Container -Credential $Credential
$count = 100
$fileName = 'sls-demo.txt'
function Get-TagPath([int]$i) { 'demo.line{0}.sensor{1:D3}' -f ([math]::Floor(($i - 1) / 10) + 1), $i }

if ($Verify) {
    foreach ($i in 1, 50, $count) {
        $p = Get-TagPath $i
        Wait-SlsCondition { "$((Invoke-SlsApi $server "nitag/v2/tags/$p/values/current").value.value)" -eq "$($i + 0.25)" } `
            -TimeoutSec 120 -IntervalMs 2000 -Message "demo tag $p = $($i + 0.25)" | Out-Null
    }
    $files = Invoke-SlsApi $server "nifile/v1/service-groups/Default/files?take=100"
    if (-not (@($files.availableFiles) | Where-Object { $_.properties.Name -eq $fileName })) { throw "demo file $fileName missing" }
    Write-Host "demo data present: tags $(Get-TagPath 1) .. $(Get-TagPath $count), file $fileName"
    return
}

# The tag service can answer 500 for a short while after authentication works.
Wait-SlsCondition { try { Invoke-SlsApi $server 'nitag/v2/tags?take=1' | Out-Null; $true } catch { $false } } -TimeoutSec 180 -IntervalMs 3000 `
    -Message 'tag service' | Out-Null
for ($i = 1; $i -le $count; $i++) {
    $p = Get-TagPath $i
    Invoke-SlsApi $server "nitag/v2/tags/$p" -Method PUT -Body @{ type = 'DOUBLE'; path = $p; keywords = @('demo'); properties = @{ line = "$([math]::Floor(($i - 1) / 10) + 1)" } } | Out-Null
    Invoke-SlsApi $server "nitag/v2/tags/$p/values/current" -Method PUT -Body @{ value = @{ type = 'DOUBLE'; value = "$($i + 0.25)" } } | Out-Null
}
$mp = [Net.Http.MultipartFormDataContent]::new()
$fc = [Net.Http.ByteArrayContent]::new([Text.Encoding]::ASCII.GetBytes(((1..2000 | ForEach-Object { "sls demo line $_" }) -join "`n")))
$fc.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('text/plain')
$mp.Add($fc, 'file', $fileName)
Invoke-SlsApi $server 'nifile/v1/service-groups/Default/upload-files' -Method POST -Content $mp | Out-Null
Write-Host "demo data created: $count tags, file $fileName"
