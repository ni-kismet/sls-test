# On-disk bootstrap of the SystemLink container agent. Runs as SYSTEM at startup (task SLS-Agent, registered at image
# build). Mirrors \\host.lan\Data\guest (the image's /opt/sls/guest, copied there by start.sh) to C:\sls\guest and runs
# the agent from it, so agent changes ship with the image layer instead of the sealed disk. Without the share it falls
# back to the last mirrored copy.
# Must stay compatible with Windows PowerShell 5.1 and ASCII-only.
$ErrorActionPreference = 'Continue'
$share = '\\host.lan\Data'
$root = 'C:\sls'
$guest = "$root\guest"
New-Item -ItemType Directory -Force -Path $guest | Out-Null
for ($i = 0; $i -lt 90 -and -not (Test-Path "$share\guest\Agent.ps1"); $i++) { Start-Sleep -Seconds 2 }
$note = 'share missing, using the last mirrored agent'
if (Test-Path "$share\guest\Agent.ps1") {
    $null = & robocopy.exe "$share\guest" $guest /MIR /R:3 /W:1 /NP /NFL /NDL /NJH /NJS
    $note = "mirrored (robocopy $LASTEXITCODE)"
    # A newer bootstrap takes effect on the next boot.
    $new = "$guest\Bootstrap.ps1"
    if ((Test-Path $new) -and ((Get-FileHash $new).Hash -ne (Get-FileHash $PSCommandPath).Hash)) { Copy-Item $new $PSCommandPath -Force; $note += ', bootstrap updated' }
}
Add-Content -Path "$root\bootstrap.log" -Value ('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $note) -Encoding ascii
if (Test-Path "$guest\Agent.ps1") {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$guest\Agent.ps1"
    exit $LASTEXITCODE
}
exit 1
