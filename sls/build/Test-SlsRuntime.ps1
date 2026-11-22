#Requires -Version 7.2
<#
.SYNOPSIS
Runtime contract tests for a SystemLink Server image (implementation-plan.md P4): default start, admin password at
start, license user + files, sls-exec, sls-logs, persistent restart. Writes out\runtime-tests\<stamp>\results.json.

.DESCRIPTION
Three containers:
  default     image as built: healthy, [sls]/[agent] lines, runtime.json "none", migration service coverage (strict
              when the image's com.ni.sls.products label lists the modules), sls-exec, sls-logs
  password    SLS_ADMIN_PASSWORD (new random password) + SLS_LICENSE_USER + a dummy .lic on a persistent volume:
              new password works, the image password is rejected, license user/file in the guest; then docker stop/start:
              settings re-applied (password "unchanged"), readiness gated again on the second boot
The image's own admin password comes from SLS_BUILD_ADMIN_PASSWORD or the build's credentials.json.

.EXAMPLE
pwsh build/Test-SlsRuntime.ps1 -Image sls-server:26.5
#>
param([string]$Image = 'sls-server:26.5', [string]$Ram = '8G', [int]$Cpu = 4)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SlsBuild.psm1') -Force
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'testkit\SlsTestKit.psm1') -Force
$imageCred = Get-SlsImageCredential -Image $Image
$outDir = Join-Path (Get-SlsRepoRoot) "out\runtime-tests\$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Set-SlsLogFile (Join-Path $outDir 'test.log')
$results = [Collections.Generic.List[object]]::new()
$metrics = [ordered]@{}
$servers = @{}

function Test-Case([string]$Name, [scriptblock]$Body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Body
        $results.Add([pscustomobject]@{ name = $Name; pass = $true; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); detail = "$detail" })
        Write-SlsLog "PASS $Name $(if ($detail) { "- $detail" })"
    } catch {
        $results.Add([pscustomobject]@{ name = $Name; pass = $false; sec = [math]::Round($sw.Elapsed.TotalSeconds, 1); detail = $_.Exception.Message })
        Write-SlsLog "FAIL $Name - $($_.Exception.Message)"
    }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-Status($s, [pscredential]$Cred) { (Invoke-SlsApi $s 'niauth/v1/auth' -Credential $Cred -PassThru).Status }

try {
    # ------------------------------------------------------------------------------------------------ default
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $d = Start-SlsServer -Image $Image -Name 'sls-p4-default' -Credential $imageCred -Ram $Ram -Cpu $Cpu
    $servers.default = $d
    $metrics.defaultHealthySec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-SlsLog "default: healthy after $($metrics.defaultHealthySec) s"

    Test-Case 'default: start hook and agent lines in docker logs' {
        $log = (& docker logs $d.Name 2>&1) -join "`n"
        foreach ($p in '[sls] ', '[agent] ', 'ephemeral overlay created on /images/base.qcow2') { Assert-True $log.Contains($p) "missing '$p'" }
        ($log -split "`n" | Where-Object { $_ -match '^\[agent\] .*ready ' } | Select-Object -First 1)
    }
    Test-Case 'default: runtime.json reports nothing to apply' {
        $rt = Get-SlsAgentFile $d 'agent/runtime.json'
        Assert-True ($rt.status -eq 'none' -and $rt.adminPassword -eq 'not-requested') "runtime.json: $($rt | ConvertTo-Json -Compress)"
        "status=$($rt.status)"
    }
    Test-Case 'default: image credential works, anonymous rejected' {
        Assert-True ((Get-Status $d $imageCred) -eq 200) 'image credential rejected'
        $a = (Invoke-SlsApi $d 'nitag/v2/tags?take=1' -Anonymous -PassThru).Status
        Assert-True ($a -eq 401) "anonymous: $a"
    }
    Test-Case 'default: migration service coverage' {
        $rows = @(Test-SlsServiceCoverage $d -WaitSec 300)
        $rows | ForEach-Object { Write-SlsLog ("  coverage {0,-22} {1,3} {2,-7} {3,5} s" -f $_.Resource, $_.Status, $_.Result, $_.Seconds) }
        $metrics.coverage = @($rows | ForEach-Object { [ordered]@{ resource = $_.Resource; route = $_.Route; status = $_.Status; result = $_.Result; seconds = $_.Seconds } })
        $products = "$(& docker image inspect -f '{{ index .Config.Labels "com.ni.sls.products" }}' $Image 2>$null)"
        $bad = @($rows | Where-Object Result -eq 'failed')
        # Images without the module products (server-only builds) only report.
        if ($products -match 'ni-systemlink-test-module' -and $products -match 'ni-systemlink-asset-module') {
            Assert-True (-not $bad) "failed: $(($bad | ForEach-Object { "$($_.Resource) $($_.Status)" }) -join ', ')"
        }
        "$(@($rows | Where-Object Result -eq 'ok').Count) ok, $(@($rows | Where-Object Result -eq 'license').Count) license, $($bad.Count) failed"
    }
    Test-Case 'sls-exec: output and exit code' {
        $r = Invoke-SlsGuest $d "Write-Output ('hello ' + `$env:COMPUTERNAME); Write-Error 'to stderr'; exit 3" -NoThrow
        Assert-True ($r.ExitCode -eq 3) "exit $($r.ExitCode)"
        Assert-True (($r.Output -join "`n") -match 'hello ') "output: $($r.Output -join ' | ')"
        Assert-True (($r.Output -join "`n") -match 'to stderr') "stderr missing: $($r.Output -join ' | ')"
        "exit 3, $($r.Output.Count) lines"
    }
    Test-Case 'sls-exec: script file (-c) and stdin give the same result' {
        $a = (& docker exec $d.Name sls-exec -c '[Environment]::OSVersion.Version.Build' 2>&1) -join ''
        $b = ('[Environment]::OSVersion.Version.Build' | & docker exec -i $d.Name sls-exec 2>&1) -join ''
        Assert-True ($a.Trim() -eq $b.Trim() -and $a.Trim() -match '^\d+$') "'$a' vs '$b'"
        "build $($a.Trim())"
    }
    Test-Case 'sls-exec: output streams while the command runs' {
        $first = $null
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        "1..3 | ForEach-Object { Write-Output `"tick `$_`"; Start-Sleep -Seconds 5 }" | & docker exec -i $d.Name sls-exec 2>&1 | ForEach-Object {
            if (-not $first -and "$_" -match 'tick 1') { $first = $sw2.Elapsed.TotalSeconds }
        }
        $total = $sw2.Elapsed.TotalSeconds
        Assert-True ($first -and $first -lt $total - 7) "first line at $first s of $total s"
        "first line at $([math]::Round($first, 1)) s, done at $([math]::Round($total, 1)) s"
    }
    Test-Case 'sls-exec: timeout cancels the guest command (exit 124)' {
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-SlsGuest $d "Set-Content C:\sls\p4-timeout.txt started; Start-Sleep -Seconds 300; Set-Content C:\sls\p4-timeout.txt finished" -TimeoutSec 10 -NoThrow
        $sec = [math]::Round($sw2.Elapsed.TotalSeconds, 1)
        Assert-True ($r.ExitCode -eq 124) "exit $($r.ExitCode)"
        Assert-True ($sec -lt 80) "took $sec s"
        Start-Sleep -Seconds 2
        $check = Invoke-SlsGuest $d "(Get-Content C:\sls\p4-timeout.txt) -join ''; @(Get-CimInstance Win32_Process -Filter `"Name='powershell.exe'`" | Where-Object { `$_.CommandLine -match 'C:\\sls\\cmd\\' -and `$_.ProcessId -ne `$PID }).Count"
        Assert-True ($check.Output[0] -eq 'started') "guest file: $($check.Output -join ' | ')"
        "exit 124 after $sec s; leftover command processes: $($check.Output[-1])"
    }
    Test-Case 'sls-logs: archive content' {
        & docker exec $d.Name sls-logs -o /tmp/p4-logs.tgz 2>&1 | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "sls-logs exit $LASTEXITCODE"
        $list = @(& docker exec $d.Name tar -tzf /tmp/p4-logs.tgz)
        & docker cp "$($d.Name):/tmp/p4-logs.tgz" (Join-Path $outDir 'default-logs.tgz') 2>&1 | Out-Null
        $list | Set-Content (Join-Path $outDir 'default-logs.txt')
        foreach ($p in 'ni/', 'windows-System.evtx', 'windows-Application.txt', 'ni-services.csv', 'nipkg-installed.txt', 'system.json', 'agent.log', 'container.txt') {
            Assert-True ($list | Where-Object { $_ -like "*$p*" }) "archive lacks $p"
        }
        $latest = "$(& docker exec $d.Name sh -c 'readlink /shared/logs/latest && ls /shared/logs/latest | wc -l')"
        Assert-True ($latest -match '\S') 'no /shared/logs/latest'
        "$($list.Count) entries; latest -> $latest"
    }
    Stop-SlsServer $d; $servers.Remove('default')

    # ------------------------------------------------------------------------------------------------ password + license, persistent
    $newPw = New-SlsPassword 'P4-'
    $newCred = New-SlsCredential 'admin' $newPw
    $lic = Join-Path $outDir 'p4-dummy.lic'
    "dummy license for runtime tests $(Get-Date -Format o)" | Set-Content $lic -Encoding ascii
    $vol = 'sls-p4-persist'
    & docker volume rm $vol 2>&1 | Out-Null
    $sw.Restart()
    $p = Start-SlsServer -Image $Image -Name 'sls-p4-password' -AdminCredential $newCred -LicenseUser 'slstest' -LicenseFile $lic -Volume $vol -Ram $Ram -Cpu $Cpu
    $servers.password = $p
    $metrics.passwordHealthySec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $rt = Get-SlsAgentFile $p 'agent/runtime.json'
    $metrics.adminPasswordSec = $rt.adminPasswordSec
    Write-SlsLog "password: healthy after $($metrics.passwordHealthySec) s (password set in $($rt.adminPasswordSec) s)"

    Test-Case 'password: runtime.json applied/set, no secret in it' {
        $raw = (& docker exec $p.Name cat /shared/agent/runtime.json) -join ''
        Assert-True ($rt.status -eq 'applied' -and $rt.adminPassword -eq 'set') "runtime.json: $raw"
        Assert-True (-not $raw.Contains($newPw)) 'password in runtime.json'
        $left = "$(& docker exec $p.Name sh -c 'ls /shared/runtime/config.json 2>/dev/null')".Trim()
        Assert-True (-not $left) 'runtime/config.json not deleted'
        "set in $($rt.adminPasswordSec) s"
    }
    Test-Case 'password: new password works, image password rejected' {
        Assert-True ((Get-Status $p $newCred) -eq 200) 'new password rejected'
        $old = Get-Status $p $imageCred
        Assert-True ($old -eq 401) "image password: $old"
        "new 200, old $old"
    }
    Test-Case 'password: docker logs do not contain it' {
        Assert-True (-not ((& docker logs $p.Name 2>&1) -join "`n").Contains($newPw)) 'password in docker logs'
        $envDump = (& docker inspect -f '{{json .Config.Env}}' $p.Name) -join ''
        # docker inspect shows container env by design; the point is: not on the command line / image history
        $hist = (& docker history --no-trunc $Image) -join "`n"
        Assert-True (-not $hist.Contains($newPw)) 'password in image history'
        "env visible to docker inspect: $($envDump.Contains($newPw))"
    }
    Test-Case 'license: user created, file placed' {
        Assert-True ($rt.licenseUser -eq 'created:slstest') "licenseUser: $($rt.licenseUser)"
        Assert-True (@($rt.licenseFiles).Count -eq 1 -and $rt.licenseFiles[0].name -eq 'p4-dummy.lic') "licenseFiles: $($rt.licenseFiles | ConvertTo-Json -Compress)"
        $g = Invoke-SlsGuest $p @'
$u = Get-LocalUser -Name slstest
$f = Join-Path $env:ProgramData 'National Instruments\License Manager\Licenses\p4-dummy.lic'
"user=$($u.Name) enabled=$($u.Enabled) users=$([bool](Get-LocalGroupMember -SID S-1-5-32-545 | Where-Object Name -like '*\slstest'))"
"file=$(Test-Path $f) bytes=$((Get-Item $f).Length)"
'@
        $o = $g.Output -join ' '
        Assert-True ($o -match 'user=slstest enabled=True users=True' -and $o -match 'file=True') $o
        $o
    }
    Test-Case 'persistent: data survives a restart, settings re-applied, readiness gated' {
        Invoke-SlsApi $p 'nitag/v2/tags/p4.persist' -Method PUT -Body @{ type = 'DOUBLE'; path = 'p4.persist' } | Out-Null
        Invoke-SlsApi $p 'nitag/v2/tags/p4.persist/values/current' -Method PUT -Body @{ value = @{ type = 'DOUBLE'; value = '9.5' } } | Out-Null
        Wait-SlsCondition { (Invoke-SlsApi $p 'nitag/v2/tags/p4.persist/values/current').value.value -eq '9.5' } -TimeoutSec 60 -Message 'tag' | Out-Null
        $boot1 = (Get-SlsAgentFile $p 'agent/ready.json').bootId
        $sw2 = [Diagnostics.Stopwatch]::StartNew()
        Invoke-SlsDocker stop -t 150 $p.Name | Out-Null
        $stopSec = [math]::Round($sw2.Elapsed.TotalSeconds, 1)
        $sw2.Restart()
        Invoke-SlsDocker start $p.Name | Out-Null
        # The ephemeral host port changes on every start (Restart-SlsServer does the same refresh).
        $fresh = Get-SlsServer -Name $p.Name -Credential $newCred
        $p.HttpPort = $fresh.HttpPort; $p.BaseUrl = $fresh.BaseUrl
        Start-Sleep -Seconds 3
        $h = "$(& docker inspect -f '{{.State.Health.Status}}' $p.Name)".Trim()
        $early = Get-SlsAgentFile $p 'agent/ready.json'
        Assert-True ($h -ne 'healthy' -and -not $early) "right after start: health=$h ready=$($early.bootId)"
        Wait-SlsServer $p -TimeoutSec 900 | Out-Null
        $restartSec = [math]::Round($sw2.Elapsed.TotalSeconds, 1)
        $rt2 = Get-SlsAgentFile $p 'agent/runtime.json'
        $ready2 = Get-SlsAgentFile $p 'agent/ready.json'
        Assert-True ($ready2.bootId -ne $boot1) 'same bootId after restart'
        Assert-True ($rt2.adminPassword -eq 'unchanged' -and $rt2.licenseUser -eq 'exists:slstest') "runtime.json: $($rt2 | ConvertTo-Json -Compress)"
        Assert-True ((Get-Status $p $newCred) -eq 200) 'password after restart'
        Wait-SlsCondition { (Invoke-SlsApi $p 'nitag/v2/tags/p4.persist/values/current').value.value -eq '9.5' } -TimeoutSec 60 -Message 'tag after restart' | Out-Null
        $metrics.persistentStopSec = $stopSec; $metrics.persistentRestartHealthySec = $restartSec
        "stop $stopSec s, healthy again after $restartSec s, password unchanged, tag kept"
    }
} catch {
    Write-SlsLog "ERROR: $($_.Exception.Message)"
    $results.Add([pscustomobject]@{ name = 'setup'; pass = $false; sec = 0; detail = $_.Exception.Message })
} finally {
    if ($results | Where-Object { -not $_.pass }) {
        foreach ($s in $servers.Values) { try { Save-SlsLogs $s -Path $outDir | Out-Null } catch { } }
    }
    foreach ($s in $servers.Values) { Stop-SlsServer $s -RemoveVolume }
}
[ordered]@{ image = $Image; imageId = "$(& docker image inspect -f '{{.Id}}' $Image)".Trim(); metrics = $metrics; tests = $results } |
    ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir 'results.json') -Encoding utf8
$failed = @($results | Where-Object { -not $_.pass }).Count
Write-SlsLog "$($results.Count - $failed)/$($results.Count) passed; $(Join-Path $outDir 'results.json')"
if ($failed) { exit 1 }
