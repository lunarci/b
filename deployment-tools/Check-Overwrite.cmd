@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-OptiScalerOverwrite.ps1" -Action Check
set "tool_result=%errorlevel%"
echo.
echo Press any key to close.
pause >nul
exit /b %tool_result%
