@echo off
setlocal

net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

echo Starting Windows remote access...
sc.exe config sshd start= auto
if errorlevel 1 goto failed

sc.exe start sshd >nul 2>&1
sc.exe query sshd | findstr /C:"RUNNING" >nul
if errorlevel 1 goto failed

netsh advfirewall firewall delete rule name="Receipt Printer Remote Setup" >nul 2>&1
netsh advfirewall firewall add rule name="Receipt Printer Remote Setup" dir=in action=allow protocol=TCP localport=22 remoteip=192.168.5.118 >nul
if errorlevel 1 goto failed

echo.
echo REMOTE ACCESS IS READY
echo Windows username: %USERNAME%
echo Windows IPv4 address:
ipconfig | findstr /I "IPv4"
echo.
echo Leave this window open and send Codex the username and IPv4 address above.
pause
exit /b 0

:failed
echo.
echo SETUP FAILED. Take a picture of this window and send it to Codex.
pause
exit /b 1
