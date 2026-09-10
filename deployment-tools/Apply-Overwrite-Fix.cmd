@echo off
setlocal
echo OptiScaler Overwrite conflict backup
echo Close Cyberpunk 2077 and run Root Builder Clear before using this tool.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-OptiScalerOverwrite.ps1" -Action Apply
set "tool_result=%errorlevel%"
echo.
echo Press any key to close.
pause >nul
exit /b %tool_result%
