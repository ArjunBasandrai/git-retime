@echo off
setlocal
pwsh.exe -NoLogo -NoProfile -File "%~dp0git-retime.ps1" %*
exit /b %errorlevel%
