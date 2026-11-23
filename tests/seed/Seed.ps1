# Test fixture: a custom seed as another repository would write it (outside src/seeds), used by test.yml through
# sls-build-image `seed: tests/seed/Seed.ps1`. Creates three STRING tags and one file; -Verify checks them.
# Contract: param(BaseUrl, Credential, Container, [switch]Verify). The build sets SLS_TESTKIT to the test kit module.
param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][string]$Container,
    [switch]$Verify)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command Get-SlsServer -ErrorAction SilentlyContinue)) { Import-Module $env:SLS_TESTKIT }
$server = Get-SlsServer -Name $Container -Credential $Credential
$tags = 'seedtest.a', 'seedtest.b', 'seedtest.c'
$fileName = 'sls-seedtest.txt'

if ($Verify) {
    foreach ($p in $tags) {
        Wait-SlsCondition { "$((Invoke-SlsApi $server "nitag/v2/tags/$p/values/current").value.value)" -eq "value of $p" } `
            -TimeoutSec 120 -IntervalMs 2000 -Message "tag $p" | Out-Null
    }
    $files = Invoke-SlsApi $server 'nifile/v1/service-groups/Default/files?take=100'
    if (-not (@($files.availableFiles) | Where-Object { $_.properties.Name -eq $fileName })) { throw "file $fileName missing" }
    Write-Host "test seed data present: $($tags -join ', '), $fileName"
    return
}

Wait-SlsCondition { try { Invoke-SlsApi $server 'nitag/v2/tags?take=1' | Out-Null; $true } catch { $false } } -TimeoutSec 180 -IntervalMs 3000 `
    -Message 'tag service' | Out-Null
foreach ($p in $tags) {
    Invoke-SlsApi $server "nitag/v2/tags/$p" -Method PUT -Body @{ type = 'STRING'; path = $p; keywords = @('seedtest') } | Out-Null
    Invoke-SlsApi $server "nitag/v2/tags/$p/values/current" -Method PUT -Body @{ value = @{ type = 'STRING'; value = "value of $p" } } | Out-Null
}
$mp = [Net.Http.MultipartFormDataContent]::new()
$fc = [Net.Http.ByteArrayContent]::new([Text.Encoding]::ASCII.GetBytes('sls-test seed fixture'))
$fc.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('text/plain')
$mp.Add($fc, 'file', $fileName)
Invoke-SlsApi $server 'nifile/v1/service-groups/Default/upload-files' -Method POST -Content $mp | Out-Null
Write-Host "test seed data created: $($tags -join ', '), $fileName"
