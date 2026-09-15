@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Complete-Setup.ps1" -Action RestoreComplete
set "addon_exit=%ERRORLEVEL%"
pause
exit /b %addon_exit%
