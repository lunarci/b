@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Complete-Setup.ps1" -Action RecoverPerformance
set "result=%errorlevel%"
pause
exit /b %result%
