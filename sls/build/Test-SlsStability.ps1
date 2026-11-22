#Requires -Version 7.2
<#
.SYNOPSIS
Soak test for a SystemLink Server image: runs CI-like jobs back to back in parallel lanes and records how each one
ends (ok, bugcheck, hang, boot failure). Measures guest stability on a given host (nested KVM on WSL2 or a CI runner).

.DESCRIPTION
Each lane runs -Jobs jobs one after the other. A job starts a fresh container, waits until it is healthy, runs the
workload for -JobMinutes and removes the container, like a CI job would. The lanes run at the same time, so they share
the host the way parallel CI jobs on one machine would (and as several lanes on a developer machine).

Workload "api" (one iteration about every 10-20 s): tag writes, a file upload, a Test Monitor product, result (with
the file) and steps, an asset, the migration coverage queries, a guest command every 5th iteration and a feed every
10th. Workload "idle" only checks liveness.

Failure detection:
  bugcheck  QEMU paused the guest (guest-panicked, image default -action panic=pause with hv-crash). The stop code
            comes from the blue screen: the script lets the paused guest continue, takes a screenshot and reads it with
            Windows OCR on a Windows host or tesseract elsewhere (apt install tesseract-ocr); without either the
            screenshot <lane>-<job>-bsod.ppm is kept for a person to read.
  hang      the guest's HTTP endpoint stays dead for -HangSec while QEMU is running and no bugcheck was reported. The
            script saves the CPU registers and a screenshot, then injects an NMI: a hung Windows guest then bugchecks
            (0x80), which confirms the guest kernel was not making progress.
  boot      not healthy within -BootTimeoutSec.
  degraded  the VM stayed up but more than 10% of the workload's API calls failed (a service never became ready).
  stall     HTTP dead for a while but recovered (logged, the job continues).
Results: out\stability\<stamp>\jobs.jsonl (one line per job), lane logs and failure artifacts.

The image's admin password comes from SLS_BUILD_ADMIN_PASSWORD or the build's credentials.json.

.PARAMETER Lane
Lane specs "name[:KEY=VALUE]...": KEY=VALUE pairs become container environment variables, except cpu=, ram= and
lock=1 (pin the guest RAM with QEMU -overcommit mem-lock=on, so the host cannot swap, migrate or compact it).
Example: -Lane 'hvn', 'hvy:HV=Y', 'hvn-2cpu:cpu=2', 'pinned:lock=1'.

.EXAMPLE
pwsh build/Test-SlsStability.ps1 -Image sls-server-mod:26.5 -Lane hvn-a, hvn-b, 'hvy:HV=Y' -Jobs 3 -JobMinutes 15
#>
param(
    [string]$Image = 'sls-server-mod:26.5',
    [string[]]$Lane = @('default'),
    [int]$Jobs = 1,
    [int]$JobMinutes = 15,
    [ValidateSet('api', 'idle')][string]$Workload = 'api',
    [int]$HangSec = 180,
    [int]$BootTimeoutSec = 900,
    [string]$Tag = '',
    [string]$OutDir
)
$ErrorActionPreference = 'Stop'
$Lane = @($Lane | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
Import-Module (Join-Path $PSScriptRoot 'SlsBuild.psm1') -Force
$testKit = Join-Path (Split-Path $PSScriptRoot -Parent) 'testkit\SlsTestKit.psm1'
$cred = Get-SlsImageCredential -Image $Image
if (-not $OutDir) { $OutDir = Join-Path (Get-SlsRepoRoot) "out\stability\$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))$(if ($Tag) { "-$Tag" })" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Set-SlsLogFile (Join-Path $OutDir 'run.log')

# Host facts recorded with every job (the guest's stability depends on the host's virtualization stack).
$hostInfo = [ordered]@{ tag = $Tag; image = $Image; workload = $Workload; lanes = $Lane.Count }
$kvm = & docker run --rm -v /sys/module:/m:ro alpine sh -c 'for m in kvm_amd kvm_intel; do [ -d /m/$m ] && for f in /m/$m/parameters/*; do echo "$m.$(basename $f)=$(cat $f)"; done; done; echo "memory=$(awk ''/^MemTotal/{t=$2}/^SwapTotal/{s=$2}END{print int(t/1048576) "G swap=" int(s/1048576) "G"}'' /proc/meminfo) thp=$(sed ''s/.*\[\(.*\)\].*/\1/'' /sys/kernel/mm/transparent_hugepage/enabled) compact_unevictable=$(cat /proc/sys/vm/compact_unevictable_allowed)"; grep -m1 "model name" /proc/cpuinfo; uname -r' 2>$null
$hostInfo.kernel = "$($kvm | Select-Object -Last 1)"
$hostInfo.cpu = "$($kvm | Where-Object { $_ -like 'model name*' })" -replace '^model name\s*:\s*', ''
$hostInfo.memory = "$($kvm | Where-Object { $_ -like 'memory=*' })"
$hostInfo.kvm = (@($kvm | Where-Object { $_ -match '^kvm_(amd|intel)\.(avic|npt|ept|nested|vls|vgif|vnmi|nrips|lbrv|enable_apicv|enable_shadow_vmcs)=' }) -replace '^kvm_(amd|intel)\.', '') -join ' '
($hostInfo | ConvertTo-Json -Compress) | Set-Content (Join-Path $OutDir 'host.json')
Write-SlsLog "stability: image $Image, lanes $($Lane -join ', '), $Jobs job(s) x $JobMinutes min, workload $Workload"
Write-SlsLog "host: $($hostInfo.cpu) | kernel $($hostInfo.kernel) | $($hostInfo.kvm) | $($hostInfo.memory)"

$laneCode = {
    param($Spec, $LaneIndex, $Cfg)
    $ErrorActionPreference = 'Stop'
    Import-Module $Cfg.TestKit -Force
    Start-Sleep -Seconds (30 * $LaneIndex)
    $parts = $Spec -split ':'
    $laneName = $parts[0]
    $envs = @{}
    $cpu = 4; $ram = '8G'; $dockerArgs = @()
    foreach ($p in $parts | Select-Object -Skip 1) {
        $k, $v = $p -split '=', 2
        if ($k -eq 'cpu') { $cpu = [int]$v } elseif ($k -eq 'ram') { $ram = $v }
        elseif ($k -eq 'lock' -and $v -in '1', 'Y') {
            # Pin guest RAM (mlock): the host cannot swap, migrate or compact it while the VM runs.
            $envs['ARGUMENTS'] = '-overcommit mem-lock=on'
            $dockerArgs = @('--ulimit', 'memlock=-1:-1', '--cap-add', 'IPC_LOCK')
        }
        else { $envs[$k] = $v }
    }
    $out = $Cfg.OutDir
    $logFile = Join-Path $out "lane-$laneName.log"
    function Log([string]$m) {
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $laneName, $m
        Write-Host $line
        Add-Content -Path $logFile -Value $line -Encoding utf8
    }
    function Mon([string]$Name, [string]$Cmd) {
        "$(& docker exec $Name sh -c "echo '$Cmd' | nc -q 1 -U /run/shm/monitor.sock" 2>$null)"
    }
    function Get-VmStatus([string]$Name) { if ((Mon $Name 'info status') -match 'VM status: (\S+(?: \([^)]*\))?)') { $Matches[1] } else { 'unknown' } }
    function Get-Panic([string]$Name) { "$(& docker exec $Name sh -c 'cat /storage/sls-panic.txt 2>/dev/null' 2>$null)".Trim() }
    function Test-Alive([string]$Name) {
        $c = "$(& docker exec $Name sh -c 'curl -s -o /dev/null -m 8 -w %{http_code} http://$(cat /run/shm/qemu.ip)/niauth/v1/user' 2>$null)".Trim()
        return $c -in '200', '401'
    }
    # QEMU paused the guest at the bugcheck notification: let Windows draw the blue screen, then OCR the stop code
    # (Windows OCR or tesseract; without either the screenshot is kept for a person to read).
    function Get-StopCode([string]$Name, [string]$Prefix) {
        Mon $Name 'cont' | Out-Null
        Start-Sleep 30
        & docker exec $Name sh -c "echo 'screendump /tmp/bsod.ppm' | nc -q 1 -U /run/shm/monitor.sock >/dev/null; sleep 1" 2>$null
        $ppm = Join-Path $out "$Prefix-bsod.ppm"
        & docker cp "${Name}:/tmp/bsod.ppm" $ppm 2>&1 | Out-Null
        if (-not (Test-Path $ppm)) { return 'no screenshot' }
        if ($IsWindows) {
            $text = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Cfg.OcrScript $ppm 2>&1) -join "`n"
            $shot = "$Prefix-bsod.png"
        } elseif (Get-Command tesseract -ErrorAction SilentlyContinue) {
            # Reads the native-size screenshot reliably (unlike Windows OCR, no upscaling needed).
            $text = (& tesseract $ppm - 2>$null) -join "`n"
            $shot = "$Prefix-bsod.ppm"
        } else { return "see $Prefix-bsod.ppm (install tesseract-ocr to read it)" }
        if ($text -match '(?mi)^stop(?: code)?:?\s*(.+)$') { return ($Matches[1].Trim().ToUpperInvariant() -replace '[ :]+', '_') }
        # A wedged guest can report the panic (hv-crash) and still never draw the blue screen.
        if ($text -notmatch 'ran into a problem') { return "no blue screen drawn, see $shot" }
        return "unreadable, see $shot"
    }
    function Save-Failure([string]$Name, [string]$Prefix) {
        $f = Join-Path $out $Prefix
        & docker logs -t $Name *> "$f-docker.log"
        & docker cp "${Name}:/storage/sls-panic.ppm" "$f-panic.ppm" 2>&1 | Out-Null
    }
    # Waits for a dead endpoint: returns 'alive' (recovered), 'bugcheck' or 'hang' (NMI injected).
    function Resolve-Dead([string]$Name, [string]$Prefix, [ref]$Detail) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $Cfg.HangSec) {
            if (Get-Panic $Name) { return 'bugcheck' }
            if (Test-Alive $Name) { $Detail.Value = "stall $([int]$sw.Elapsed.TotalSeconds) s"; return 'alive' }
            Start-Sleep 10
        }
        if (Get-Panic $Name) { return 'bugcheck' }
        $status = Get-VmStatus $Name
        $regs = Mon $Name 'info registers -a'
        $regs | Set-Content "$(Join-Path $out $Prefix)-registers.txt"
        $rfl = @([regex]::Matches($regs, 'RFL=([0-9a-f]+)') | ForEach-Object { $v = [Convert]::ToInt64($_.Groups[1].Value, 16); '{0}{1}' -f $(if ($v -band 0x200) { 'IF' } else { 'if' }), $(if ($v -band 0x100) { '+TF' } else { '' }) }) -join ','
        & docker exec $Name sh -c "echo 'screendump /tmp/hang.ppm' | nc -q 1 -U /run/shm/monitor.sock >/dev/null; sleep 1" 2>$null
        & docker cp "${Name}:/tmp/hang.ppm" "$(Join-Path $out $Prefix)-hang.ppm" 2>&1 | Out-Null
        Mon $Name 'nmi' | Out-Null
        $nmi = 'no bugcheck after NMI'
        for ($i = 0; $i -lt 12; $i++) { Start-Sleep 5; if (Get-Panic $Name) { $nmi = "NMI -> bugcheck $(Get-StopCode $Name $Prefix)"; break } }
        $Detail.Value = "HTTP dead $($Cfg.HangSec) s, VM $status, cpus $rfl; $nmi"
        return 'hang'
    }

    $wcred = $Cfg.cred
    for ($job = 1; $job -le $Cfg.Jobs; $job++) {
        $name = "soak-$laneName-$job"
        $prefix = "$laneName-$job"
        & docker rm -f -v $name 2>&1 | Out-Null
        $rec = [ordered]@{ tag = $Cfg.Tag; lane = $laneName; job = $job; cpu = $cpu; ram = $ram; env = (($envs.Keys | Sort-Object | ForEach-Object { "$_=$($envs[$_])" }) -join ' ')
            start = (Get-Date).ToUniversalTime().ToString('o'); healthySec = $null; runSec = 0; outcome = 'ok'; failSec = $null; detail = ''
            iterations = 0; opsOk = 0; opsFailed = 0; stalls = 0; errors = @() }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $s = Start-SlsServer -Image $Cfg.Image -Name $name -Credential $wcred -Env $envs -DockerArgs $dockerArgs -Cpu $cpu -Ram $ram -NoWait
            # ---- boot
            while ($true) {
                $h = "$(& docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' $name 2>$null)".Trim()
                if ($h -eq 'running|healthy') { $rec.healthySec = [int]$sw.Elapsed.TotalSeconds; break }
                if ($h -notlike 'running|*') { $rec.outcome = 'exited'; $rec.detail = "container $h during boot"; break }
                if (Get-Panic $name) { $rec.outcome = 'bugcheck'; $rec.detail = 'during boot'; break }
                if ($sw.Elapsed.TotalSeconds -ge $Cfg.BootTimeoutSec) { $rec.outcome = 'boot'; $rec.detail = "not healthy after $($Cfg.BootTimeoutSec) s (VM $(Get-VmStatus $name), HTTP alive $(Test-Alive $name))"; break }
                Start-Sleep 5
            }
            if ($rec.outcome -eq 'ok') {
                Log "job $job healthy in $($rec.healthySec) s"
                # Like a CI job: wait until every module service answers (Test Monitor lags healthy by ~30 s).
                $cov = @(Test-SlsServiceCoverage $s -WaitSec 180 | Where-Object Result -ne 'ok')
                if ($cov) { $rec.errors += "coverage at start: $(($cov | ForEach-Object { "$($_.Resource) $($_.Status)" }) -join ', ')" }
                $t0 = [Diagnostics.Stopwatch]::StartNew()
                $iter = 0
                $partNumber = "SOAK-$laneName-$job"
                while ($t0.Elapsed.TotalMinutes -lt $Cfg.JobMinutes) {
                    $iter++
                    $it = @{ failed = 0; dead = 0 }
                    $op = {
                        param([string]$OpName, [scriptblock]$Body)
                        if ($it.dead) { return $null }
                        try { $r = & $Body; $rec.opsOk++; return $r }
                        catch {
                            $rec.opsFailed++; $it.failed++
                            $m = $_.Exception.Message
                            if ($m -match 'timed out|actively refused|No connection|forcibly closed|-> 50[234] |-> 0 |canceled|An error occurred while sending') { $it.dead++ }
                            if ($rec.errors.Count -lt 30) { $rec.errors += "[$([int]$t0.Elapsed.TotalSeconds)s] ${OpName}: $($m.Substring(0, [Math]::Min(160, $m.Length)))" }
                            return $null
                        }
                    }
                    if ($Cfg.Workload -eq 'api') {
                        & $op 'tags' {
                            for ($t = 1; $t -le 20; $t++) {
                                $p = "soak.$laneName.t$t"
                                if ($iter -eq 1) { Invoke-SlsApi $s "nitag/v2/tags/$p" -Method PUT -Body @{ type = 'DOUBLE'; path = $p; keywords = @('soak') } | Out-Null }
                                Invoke-SlsApi $s "nitag/v2/tags/$p/values/current" -Method PUT -Body @{ value = @{ type = 'DOUBLE'; value = "$($iter + $t / 100)" } } | Out-Null
                            }
                        } | Out-Null
                        $fileId = & $op 'file' {
                            $mp = [Net.Http.MultipartFormDataContent]::new()
                            $fc = [Net.Http.ByteArrayContent]::new([Text.Encoding]::ASCII.GetBytes(('soak data line' * 4096)))
                            $fc.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('text/plain')
                            $mp.Add($fc, 'file', "soak-$laneName-$job-$iter.txt")
                            ((Invoke-SlsApi $s 'nifile/v1/service-groups/Default/upload-files' -Method POST -Content $mp).uri -split '/')[-1]
                        }
                        if ($iter -eq 1) {
                            & $op 'product' { Invoke-SlsApi $s 'nitestmonitor/v2/products' -Method POST -Body @{ products = @(@{ partNumber = $partNumber; name = 'Soak product'; family = 'soak' }) } } | Out-Null
                        }
                        $resultId = & $op 'result' {
                            $b = @{ results = @(@{ programName = 'soak'; partNumber = $partNumber; serialNumber = "SN-$iter"; operator = 'soak'
                                        status = @{ statusType = 'PASSED'; statusName = 'Passed' }; totalTimeInSeconds = 1.5; fileIds = @($fileId | Where-Object { $_ }) }) }
                            (Invoke-SlsApi $s 'nitestmonitor/v2/results' -Method POST -Body $b).results[0].id
                        }
                        if ($resultId) {
                            & $op 'steps' {
                                $steps = 1..5 | ForEach-Object { @{ stepId = [guid]::NewGuid().ToString(); resultId = $resultId; name = "step $_"; stepType = 'NumericLimitTest'
                                        status = @{ statusType = 'PASSED'; statusName = 'Passed' }; totalTimeInSeconds = 0.1 } }
                                Invoke-SlsApi $s 'nitestmonitor/v2/steps' -Method POST -Body @{ steps = @($steps) }
                            } | Out-Null
                        }
                        & $op 'asset' {
                            Invoke-SlsApi $s 'niapm/v1/assets' -Method POST -Body @{ assets = @(@{ name = "soak $laneName $job $iter"; modelName = 'Soak model'; modelNumber = 1; vendorName = 'NI'; vendorNumber = 1
                                        serialNumber = "SOAK-$laneName-$job-$iter"; busType = 'ACCESSORY'; assetType = 'GENERIC'
                                        location = @{ physicalLocation = 'soak lab'; state = @{ assetPresence = 'PRESENT' } } }) }
                        } | Out-Null
                        & $op 'query' {
                            $rows = Test-SlsServiceCoverage $s
                            $bad = @($rows | Where-Object Result -ne 'ok')
                            if ($bad) { throw "coverage: $(($bad | ForEach-Object { "$($_.Resource) -> $($_.Status) " }) -join ', ')" }
                            Invoke-SlsApi $s 'nitestmonitor/v2/query-results' -Method POST -Body @{ filter = "partNumber == `"$partNumber`""; take = 10 } | Out-Null
                        } | Out-Null
                        if ($iter % 5 -eq 0) {
                            & $op 'guest' { $g = Invoke-SlsGuest $s '(Get-Service ni* | Where-Object Status -eq Running).Count' -TimeoutSec 120; if (-not "$($g.Output)".Trim()) { throw 'no output' } } | Out-Null
                        }
                        if ($iter % 10 -eq 0) {
                            & $op 'feed' { Invoke-SlsApi $s 'nirepo/v1/feeds' -Method POST -Body @{ name = "soak-$laneName-$job-$iter"; description = 'soak'; platform = 'WINDOWS' } } | Out-Null
                        }
                    } else {
                        & $op 'alive' { if (-not (Test-Alive $name)) { throw 'HTTP -> 0 not alive' } } | Out-Null
                        Start-Sleep 15
                    }
                    $rec.iterations = $iter
                    if (Get-Panic $name) { $rec.outcome = 'bugcheck'; break }
                    if ($it.dead -gt 0 -and -not (Test-Alive $name)) {
                        $detail = ''
                        $res = Resolve-Dead $name $prefix ([ref]$detail)
                        if ($res -eq 'alive') { $rec.stalls++; Log "job $job $detail (iteration $iter)"; continue }
                        $rec.outcome = $res; $rec.detail = $detail
                        break
                    }
                    Start-Sleep 5
                }
                if ($rec.outcome -ne 'ok') { $rec.failSec = [int]$t0.Elapsed.TotalSeconds + $rec.healthySec }
                elseif ($rec.opsFailed -gt 0.1 * ($rec.opsOk + $rec.opsFailed)) {
                    # The VM survived but a service kept failing (for example Test Monitor 503 after a slow boot).
                    $rec.outcome = 'degraded'; $rec.detail = "$([int](100 * $rec.opsFailed / ($rec.opsOk + $rec.opsFailed)))% of ops failed"
                }
            }
            if ($rec.outcome -ne 'ok') { Save-Failure $name $prefix }
            if ($rec.outcome -eq 'bugcheck') {
                # sls-panic.txt starts with the UTC time the watcher saw the panic (10 s polling).
                if ((Get-Panic $name) -match '^(\S+Z)') { $rec.failSec = [int]([DateTimeOffset]::Parse($Matches[1]) - [DateTimeOffset]::Parse($rec.start)).TotalSeconds }
                $rec.detail = (@($rec.detail, "stop $(Get-StopCode $name $prefix)") | Where-Object { $_ }) -join '; '
            }
        } catch {
            $rec.outcome = 'error'; $rec.detail = $_.Exception.Message
            Save-Failure $name $prefix
        } finally {
            $rec.runSec = [int]$sw.Elapsed.TotalSeconds
            & docker rm -f -v $name 2>&1 | Out-Null
        }
        Log ("job $job {0} after {1} s{2} - {3} iterations, ops ok {4} failed {5}, stalls {6}" -f $rec.outcome.ToUpper(), $(if ($rec.failSec) { $rec.failSec } else { $rec.runSec }), $(if ($rec.detail) { " ($($rec.detail))" }), $rec.iterations, $rec.opsOk, $rec.opsFailed, $rec.stalls)
        foreach ($e in $rec.errors | Select-Object -First 5) { Log "  $e" }
        $mtx = [Threading.Mutex]::new($false, 'Global\sls-stability-jobs')
        [void]$mtx.WaitOne()
        try { ([pscustomobject]$rec | ConvertTo-Json -Compress -Depth 5) | Add-Content -Path (Join-Path $out 'jobs.jsonl') -Encoding utf8 } finally { $mtx.ReleaseMutex() }
    }
}.ToString()

$ocrScript = Join-Path $OutDir 'read-screen.ps1'
# Windows PowerShell 5.1 helper: PPM screenshot -> PNG -> Windows OCR text (WinRT is not reachable from pwsh 7).
@'
param([string]$Path)
Add-Type -AssemblyName System.Drawing, System.Runtime.WindowsRuntime
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System; using System.Drawing; using System.Drawing.Imaging; using System.IO; using System.Runtime.InteropServices;
public static class Ppm {
    public static void ToPng(string src, string dst) {
        byte[] b = File.ReadAllBytes(src); int i = 0; string[] f = new string[4];
        for (int n = 0; n < 4; ) {
            while (char.IsWhiteSpace((char)b[i])) i++;
            if (b[i] == 35) { while (b[i] != 10) i++; continue; }
            int s = i; while (!char.IsWhiteSpace((char)b[i])) i++;
            f[n++] = System.Text.Encoding.ASCII.GetString(b, s, i - s);
        }
        i++; int w = int.Parse(f[1]), h = int.Parse(f[2]);
        using (var bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb)) {
            var d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, bmp.PixelFormat);
            var row = new byte[d.Stride];
            for (int y = 0; y < h; y++) {
                for (int x = 0; x < w; x++) { int o = i + (y * w + x) * 3; row[x * 3] = b[o + 2]; row[x * 3 + 1] = b[o + 1]; row[x * 3 + 2] = b[o]; }
                Marshal.Copy(row, 0, new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), d.Stride);
            }
            bmp.UnlockBits(d);
            // 2x upscale: Windows OCR misreads the small stop code font (O -> C) at native size.
            using (var big = new Bitmap(w * 2, h * 2))
            using (var g = Graphics.FromImage(big)) {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(bmp, 0, 0, w * 2, h * 2);
                big.Save(dst, ImageFormat.Png);
            }
        }
    }
}
"@
$png = [IO.Path]::ChangeExtension($Path, '.png'); [Ppm]::ToPng($Path, $png)
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); $task.Wait(-1) | Out-Null; $task.Result }
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$res = Await ([Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages().RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
$stream.Dispose(); Remove-Item $Path
$res.Lines | ForEach-Object { $_.Text }
'@ | Set-Content -Path $ocrScript -Encoding utf8

# Host memory sampler: one line every 15 s (the guest's RAM moves when the host swaps, migrates or compacts pages).
$sampler = "soak-vmstat-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
$sample = 'echo "time memAvailMB swapUsedMB pswpout pgmigrate_success compact_stall thp_fault_alloc"; while :; do ' +
    'm=$(awk ''/^MemAvailable/{a=$2}/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print int(a/1024), int((t-f)/1024)}'' /proc/meminfo); ' +
    'v=$(awk ''$1~/^(pswpout|pgmigrate_success|compact_stall|thp_fault_alloc)$/{printf "%s ", $2}'' /proc/vmstat); ' +
    'echo "$(date -u +%H:%M:%S) $m $v"; sleep 15; done'
& docker run -d --rm --name $sampler alpine sh -c $sample | Out-Null
$cfg = @{ TestKit = $testKit; OutDir = $OutDir; HangSec = $HangSec; Cred = $cred; Jobs = $Jobs; Tag = $Tag; Image = $Image
    BootTimeoutSec = $BootTimeoutSec; JobMinutes = $JobMinutes; Workload = $Workload; OcrScript = $ocrScript }
try {
    # Lanes start 30 s apart so the first boots are not in lockstep.
    $Lane | ForEach-Object -ThrottleLimit $Lane.Count -Parallel {
        & ([scriptblock]::Create($using:laneCode)) $_ ([array]::IndexOf($using:Lane, $_)) $using:cfg
    }
}
finally {
    & docker logs $sampler *> (Join-Path $OutDir 'host-memory.log')
    & docker rm -f $sampler 2>&1 | Out-Null
}

$records = @(Get-Content (Join-Path $OutDir 'jobs.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
Write-SlsLog "=== summary ($($records.Count) jobs)"
foreach ($g in $records | Group-Object lane) {
    $byOutcome = ($g.Group | Group-Object outcome | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    $minutes = [math]::Round(($g.Group | ForEach-Object { if ($_.failSec) { $_.failSec } else { $_.runSec } } | Measure-Object -Sum).Sum / 60, 1)
    Write-SlsLog ("{0,-12} {1} | {2} VM-min | {3}" -f $g.Name, $g.Group[0].env, $minutes, $byOutcome)
}
Write-SlsLog "results: $OutDir"
