@echo off
rem Run by dockurr/windows at first logon (C:\OEM\install.bat). Hands off to a SYSTEM startup task so the
rem SystemLink install survives reboots and does not depend on the logged-on session.
if not exist C:\sls-install mkdir C:\sls-install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\OEM\sls\Start-Install.ps1" > C:\sls-install\bootstrap.log 2>&1
if not exist \\host.lan\Data\install mkdir \\host.lan\Data\install
copy /y C:\sls-install\bootstrap.log \\host.lan\Data\install\bootstrap.log >nul 2>&1
