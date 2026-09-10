@echo off
setlocal
echo Restore an exact OptiScaler Overwrite backup transaction
echo Close Cyberpunk 2077 and run Root Builder Clear before restoring.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-OptiScalerOverwrite.ps1" -Action Restore
set "tool_result=%errorlevel%"
echo.
echo Press any key to close.
pause >nul
exit /b %tool_result%
