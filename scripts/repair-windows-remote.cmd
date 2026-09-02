@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-windows-remote.ps1"
set "repair_exit=%ERRORLEVEL%"
echo.
if not "%repair_exit%"=="0" echo Send the red REMOTE REPAIR FAILED message to Codex.
pause
exit /b %repair_exit%
