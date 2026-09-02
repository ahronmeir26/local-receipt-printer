@echo off
setlocal

net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "SSH_DIR=%ProgramData%\ssh"
set "SSH_LOG_DIR=%ProgramData%\ssh\logs"

echo Repairing Windows OpenSSH Error 1067...
if not exist "%SSH_DIR%" mkdir "%SSH_DIR%"
if not exist "%SSH_LOG_DIR%" mkdir "%SSH_LOG_DIR%"

rem Microsoft requires SYSTEM and Administrators full control, with other
rem authenticated users limited to read and execute on these directories.
takeown.exe /F "%SSH_DIR%" /A >nul
icacls.exe "%SSH_DIR%" /reset >nul
icacls.exe "%SSH_DIR%" /inheritance:r >nul
icacls.exe "%SSH_DIR%" /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-11:RX" >nul
if errorlevel 1 goto failed

takeown.exe /F "%SSH_LOG_DIR%" /A >nul
icacls.exe "%SSH_LOG_DIR%" /reset >nul
icacls.exe "%SSH_LOG_DIR%" /inheritance:r >nul
icacls.exe "%SSH_LOG_DIR%" /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-11:RX" >nul
if errorlevel 1 goto failed

"%WINDIR%\System32\OpenSSH\ssh-keygen.exe" -A
if errorlevel 1 goto failed

"%WINDIR%\System32\OpenSSH\sshd.exe" -t
if errorlevel 1 goto failed

sc.exe config sshd start= auto >nul
sc.exe start sshd
if errorlevel 1 goto failed

netsh advfirewall firewall delete rule name="Receipt Printer Remote Setup" >nul 2>&1
netsh advfirewall firewall add rule name="Receipt Printer Remote Setup" dir=in action=allow protocol=TCP localport=22 remoteip=192.168.5.118 >nul
if errorlevel 1 goto failed

echo.
echo SSH IS FIXED AND RUNNING
echo Windows username: %USERNAME%
ipconfig | findstr /I "IPv4"
echo.
pause
exit /b 0

:failed
echo.
echo REPAIR FAILED. The latest OpenSSH events follow:
wevtutil.exe qe "OpenSSH/Operational" /c:5 /rd:true /f:text 2>nul
echo.
echo Take a picture of this window and send it to Codex.
pause
exit /b 1
