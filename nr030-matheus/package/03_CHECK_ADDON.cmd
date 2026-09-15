@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" -Action Check
set "addon_exit=%ERRORLEVEL%"
pause
exit /b %addon_exit%
