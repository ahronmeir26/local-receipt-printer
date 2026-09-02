param(
  [string]$MacAddress = '192.168.5.118'
)

$ErrorActionPreference = 'Stop'

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
  Write-Host 'Requesting administrator approval...'
  $arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', ('"' + $PSCommandPath + '"'),
    '-MacAddress', $MacAddress
  )
  $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
  exit $process.ExitCode
}

try {
  Write-Host '[1/4] Finding the installed SSH service...'
  $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if (-not $service) {
    throw 'OpenSSH installed, but its sshd service is not registered yet. Restart Windows once, then run this repair again.'
  }

  Write-Host '[2/4] Preparing and starting SSH...'
  $keyGenerator = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
  if (Test-Path $keyGenerator) {
    & $keyGenerator -A
    if ($LASTEXITCODE -ne 0) {
      throw "ssh-keygen failed with status $LASTEXITCODE."
    }
  }

  Set-Service -Name sshd -StartupType Automatic
  if ((Get-Service -Name sshd).Status -ne 'Running') {
    Start-Service -Name sshd
  }

  $service = Get-Service -Name sshd
  if ($service.Status -ne 'Running') {
    throw "The sshd service is $($service.Status), not Running."
  }

  Write-Host '[3/4] Allowing this Mac through Windows Firewall...'
  $firewallName = 'LocalReceiptPrinter-OpenSSH-Mac'
  $rule = Get-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue
  if ($rule) {
    Set-NetFirewallRule -Name $firewallName -Enabled True -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -RemoteAddress $MacAddress
  } else {
    New-NetFirewallRule `
      -Name $firewallName `
      -DisplayName 'OpenSSH from receipt-printer Mac' `
      -Enabled True `
      -Direction Inbound `
      -Protocol TCP `
      -Action Allow `
      -LocalPort 22 `
      -RemoteAddress $MacAddress `
      -Profile Any | Out-Null
  }

  Write-Host '[4/4] Reading connection details...'
  $addresses = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.PrefixOrigin -ne 'WellKnown'
    } |
    Select-Object -ExpandProperty IPAddress -Unique

  Write-Host ''
  Write-Host 'REMOTE SETUP IS READY' -ForegroundColor Green
  Write-Host "Windows username: $env:USERNAME"
  Write-Host "Windows IP address(es): $($addresses -join ', ')"
  Write-Host "Only the Mac at $MacAddress was added to the new firewall rule."
  Write-Host 'Use the Windows account password, not the Windows Hello PIN.'
  Write-Host ''
  exit 0
} catch {
  Write-Host ''
  Write-Host 'REMOTE REPAIR FAILED:' -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host ''
  exit 1
}
