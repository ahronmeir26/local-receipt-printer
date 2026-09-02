@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable-windows-remote.ps1"
set "setup_exit=%ERRORLEVEL%"
echo.
if not "%setup_exit%"=="0" echo Remote setup failed with status %setup_exit%.
pause
exit /b %setup_exit%
