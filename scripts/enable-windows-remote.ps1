param()

$ErrorActionPreference = 'Stop'

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
  Write-Host 'Requesting administrator approval to enable Windows OpenSSH...'
  $arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $PSCommandPath + '"')
  ) -join ' '
  $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
  exit $process.ExitCode
}

Write-Host 'Checking Windows OpenSSH Server...'
$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if ($capability.State -ne 'Installed') {
  Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

$builtInFirewallRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
$firewallName = 'LocalReceiptPrinter-OpenSSH-Private'
if ($builtInFirewallRule) {
  $builtInFirewallRule | Set-NetFirewallRule -Enabled True -Profile Private -RemoteAddress LocalSubnet
} elseif (-not (Get-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule `
    -Name $firewallName `
    -DisplayName 'OpenSSH for Local Receipt Printer setup' `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -Action Allow `
    -LocalPort 22 `
    -RemoteAddress LocalSubnet `
    -Profile Private | Out-Null
}

$privateProfiles = Get-NetConnectionProfile | Where-Object { $_.IPv4Connectivity -ne 'Disconnected' }
if ($privateProfiles.NetworkCategory -contains 'Public') {
  Write-Warning 'The active Windows network is Public. Change it to Private before connecting from the Mac; the SSH firewall rule intentionally permits Private networks only.'
}

$addresses = Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
  Select-Object -ExpandProperty IPAddress -Unique

Write-Host ''
Write-Host 'Remote setup is enabled.' -ForegroundColor Green
Write-Host "Windows username: $env:USERNAME"
Write-Host "Windows IP address(es): $($addresses -join ', ')"
Write-Host 'Use the Windows account password for SSH. A Windows Hello PIN is not an SSH password.'
Write-Host ''
