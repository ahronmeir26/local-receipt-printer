@echo off
setlocal

net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "SOURCE_URL=http://192.168.5.118:8765"
set "INSTALL_TEMP=%TEMP%\LocalReceiptPrinterNetworkInstall"

echo Downloading the Local Receipt Printer application from the Mac...
if not exist "%INSTALL_TEMP%" mkdir "%INSTALL_TEMP%"
set "INSTALL_STAGE=downloading SSH repair"
curl.exe -fL "%SOURCE_URL%/s" -o "%INSTALL_TEMP%\configure-ssh.ps1"
if errorlevel 1 goto failed
set "INSTALL_STAGE=downloading Mac public key"
curl.exe -fL "%SOURCE_URL%/k" -o "%INSTALL_TEMP%\mac-key.pub"
if errorlevel 1 goto failed
set "INSTALL_STAGE=downloading application archive"
curl.exe -fL "%SOURCE_URL%/a" -o "%INSTALL_TEMP%\app.zip"
if errorlevel 1 goto failed
set "INSTALL_STAGE=downloading application installer"
curl.exe -fL "%SOURCE_URL%/w" -o "%INSTALL_TEMP%\install.ps1"
if errorlevel 1 goto failed

echo.
echo Configuring passwordless SSH for automated development...
set "INSTALL_STAGE=configuring SSH"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_TEMP%\configure-ssh.ps1" -PublicKeyPath "%INSTALL_TEMP%\mac-key.pub"
if errorlevel 1 goto failed

echo.
echo Installing and verifying the application. Node.js will be downloaded automatically.
set "INSTALL_STAGE=installing and verifying printer application"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_TEMP%\install.ps1" -ArchivePath "%INSTALL_TEMP%\app.zip"
if errorlevel 1 goto failed

echo.
echo INSTALLATION IS COMPLETE
echo Open http://127.0.0.1:17890 in Edge on this Windows computer.
start "" "http://127.0.0.1:17890"
echo.
pause
exit /b 0

:failed
set "FAILED_STATUS=%ERRORLEVEL%"
curl.exe -sS -X POST -H "Content-Type: text/plain" --data-binary "Windows launcher failed during %INSTALL_STAGE% with status %FAILED_STATUS%." "%SOURCE_URL%/report" >nul 2>&1
echo.
echo INSTALLATION FAILED, AND THE ERROR WAS REPORTED TO CODEX AUTOMATICALLY.
echo You do not need to take or send a picture.
pause
exit /b 1
