param(
  [Parameter(Mandatory=$true)]
  [string]$PublicKeyPath,
  [string]$MacAddress = '192.168.5.118',
  [string]$ReportUrl = 'http://192.168.5.118:8765/report'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$report = [ordered]@{
  success = $false
  computer = $env:COMPUTERNAME
  username = $env:USERNAME
  identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  time = [DateTime]::Now.ToString('o')
}

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Executable exited with status $LASTEXITCODE."
  }
}

function Test-LocalTcpPort([int]$Port) {
  $client = [Net.Sockets.TcpClient]::new()
  try {
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    if (-not $task.Wait([TimeSpan]::FromSeconds(3))) { return $false }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

function Register-SshdService([string]$SshdPath) {
  $existing = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($existing) {
    if ($existing.Status -ne 'Stopped') {
      Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
    }
    & "$env:WINDIR\System32\sc.exe" delete sshd | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the broken sshd service (status $LASTEXITCODE)." }
    for ($attempt = 0; $attempt -lt 40; $attempt += 1) {
      if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { break }
      Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
      throw 'The broken sshd service is still pending deletion.'
    }
  }

  Invoke-Checked "$env:WINDIR\System32\sc.exe" @(
    'create', 'sshd',
    'binPath=', $SshdPath,
    'start=', 'auto',
    'obj=', 'LocalSystem',
    'DisplayName=', 'OpenSSH SSH Server'
  )
  Invoke-Checked "$env:WINDIR\System32\sc.exe" @(
    'description', 'sshd', 'Secure Shell Server for remote development.'
  )
}

function Set-SshDataPermissions([string]$SshDataDirectory) {
  $systemSid = '*S-1-5-18'
  $administratorsSid = '*S-1-5-32-544'
  $authenticatedUsersSid = '*S-1-5-11'
  $icacls = "$env:WINDIR\System32\icacls.exe"
  $takeown = "$env:WINDIR\System32\takeown.exe"

  function Set-ExactDirectoryAcl([string]$Path) {
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $authenticatedUsers = [Security.Principal.SecurityIdentifier]::new('S-1-5-11')
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $none, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, $none, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($authenticatedUsers, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $inheritance, $none, $allow))
    Set-Acl -LiteralPath $Path -AclObject $acl
  }

  function Set-ExactFileAcl([string]$Path, [bool]$AllowAuthenticatedRead) {
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $authenticatedUsers = [Security.Principal.SecurityIdentifier]::new('S-1-5-11')
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetOwner($administrators)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($administrators, [Security.AccessControl.FileSystemRights]::FullControl, $allow))
    if ($AllowAuthenticatedRead) {
      $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($authenticatedUsers, [Security.AccessControl.FileSystemRights]::ReadAndExecute, $allow))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
  }

  Invoke-Checked $takeown @('/F', $SshDataDirectory, '/A')
  Set-ExactDirectoryAcl $SshDataDirectory

  $configPath = Join-Path $SshDataDirectory 'sshd_config'
  if (Test-Path -LiteralPath $configPath) {
    Invoke-Checked $takeown @('/F', $configPath, '/A')
    Set-ExactFileAcl $configPath $true
  }

  foreach ($hostKey in @(Get-ChildItem -LiteralPath $SshDataDirectory -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -match '^ssh_host_.+_key$'
  })) {
    Invoke-Checked $takeown @('/F', $hostKey.FullName, '/A')
    Set-ExactFileAcl $hostKey.FullName $false
  }

  $logsPath = Join-Path $SshDataDirectory 'logs'
  $logsBackupPath = Join-Path $SshDataDirectory 'logs-before-local-receipt-printer-repair'
  if ((Test-Path -LiteralPath $logsPath) -and -not (Test-Path -LiteralPath $logsBackupPath)) {
    Move-Item -LiteralPath $logsPath -Destination $logsBackupPath
  }
  New-Item -ItemType Directory -Force -Path $logsPath | Out-Null
  Invoke-Checked $takeown @('/F', $logsPath, '/A')
  Set-ExactDirectoryAcl $logsPath
}

function Get-SshdForegroundDiagnostic([string]$SshdPath) {
  $stdoutPath = Join-Path $env:TEMP "sshd-debug-$PID.stdout.txt"
  $stderrPath = Join-Path $env:TEMP "sshd-debug-$PID.stderr.txt"
  try {
    Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
    $process = Start-Process `
      -FilePath $SshdPath `
      -ArgumentList @('-ddd', '-e') `
      -RedirectStandardOutput $stdoutPath `
      -RedirectStandardError $stderrPath `
      -PassThru `
      -WindowStyle Hidden
    $exited = $process.WaitForExit(4000)
    if (-not $exited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    return [ordered]@{
      exitedWithinFourSeconds = $exited
      exitCode = if ($exited) { $process.ExitCode } else { $null }
      stdout = if (Test-Path -LiteralPath $stdoutPath) { [string[]][IO.File]::ReadAllLines($stdoutPath) | Select-Object -Last 100 } else { @() }
      stderr = if (Test-Path -LiteralPath $stderrPath) { [string[]][IO.File]::ReadAllLines($stderrPath) | Select-Object -Last 100 } else { @() }
    }
  } catch {
    return [ordered]@{ diagnosticError = $_.Exception.Message }
  }
}

function Start-SshdFallbackTask([string]$SshdPath, [string]$SshDataDirectory) {
  $taskName = 'Local Receipt Printer SSH Listener'
  $logPath = Join-Path $SshDataDirectory 'logs\sshd-task.log'
  Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

  $action = New-ScheduledTaskAction -Execute $SshdPath -Argument "-D -E `"$logPath`""
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable
  Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Boot-time SYSTEM fallback for OpenSSH when the Windows sshd service registration is broken.' `
    -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName

  for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
    if (Test-LocalTcpPort 22) { return $taskName }
    Start-Sleep -Milliseconds 500
  }
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
  $taskLog = if (Test-Path -LiteralPath $logPath) { ([IO.File]::ReadAllText($logPath) -split "`r?`n") | Select-Object -Last 100 } else { @() }
  throw "The fallback SSH task did not open port 22. State: $($task.State); last result: $($taskInfo.LastTaskResult); log: $($taskLog -join ' | ')"
}

try {
  if (-not (Test-Administrator)) {
    throw 'SSH configuration must run as Administrator.'
  }
  if (-not (Test-Path -LiteralPath $PublicKeyPath)) {
    throw 'The Mac SSH public key file was not downloaded.'
  }

  $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if (-not $service) {
    Write-Host 'Installing Windows OpenSSH Server. This one-time Windows operation can take several minutes...'
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($capability.State -ne 'Installed') {
      Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
  }
  if (-not $service) { throw 'Windows did not register the sshd service.' }

  & "$env:WINDIR\System32\sc.exe" failure sshd reset= 0 actions= none/0 | Out-Null
  Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue

  $openSshDirectory = Join-Path $env:WINDIR 'System32\OpenSSH'
  $sshdPath = Join-Path $openSshDirectory 'sshd.exe'
  $keyGeneratorPath = Join-Path $openSshDirectory 'ssh-keygen.exe'
  if (-not (Test-Path -LiteralPath $sshdPath)) { throw "sshd.exe is missing from $openSshDirectory." }

  $sshDataDirectory = Join-Path $env:ProgramData 'ssh'
  New-Item -ItemType Directory -Force -Path $sshDataDirectory | Out-Null
  if (Test-Path -LiteralPath $keyGeneratorPath) {
    Invoke-Checked $keyGeneratorPath @('-A')
  }
  Set-SshDataPermissions $sshDataDirectory
  Invoke-Checked $sshdPath @('-t')

  $publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
  if ($publicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)\s+') {
    throw 'The downloaded Mac SSH public key is invalid.'
  }
  $authorizedKeysPath = Join-Path $sshDataDirectory 'administrators_authorized_keys'
  $existingKeys = if (Test-Path -LiteralPath $authorizedKeysPath) {
    @(Get-Content -LiteralPath $authorizedKeysPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  } else {
    @()
  }
  if ($existingKeys -notcontains $publicKey) { $existingKeys += $publicKey }
  [IO.File]::WriteAllText($authorizedKeysPath, (($existingKeys -join "`r`n") + "`r`n"), [Text.ASCIIEncoding]::new())
  $authorizedKeysAcl = [Security.AccessControl.FileSecurity]::new()
  $authorizedKeysSystem = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
  $authorizedKeysAdministrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
  $authorizedKeysAllow = [Security.AccessControl.AccessControlType]::Allow
  $authorizedKeysAcl.SetOwner($authorizedKeysAdministrators)
  $authorizedKeysAcl.SetAccessRuleProtection($true, $false)
  $authorizedKeysAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($authorizedKeysSystem, [Security.AccessControl.FileSystemRights]::FullControl, $authorizedKeysAllow))
  $authorizedKeysAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($authorizedKeysAdministrators, [Security.AccessControl.FileSystemRights]::FullControl, $authorizedKeysAllow))
  Set-Acl -LiteralPath $authorizedKeysPath -AclObject $authorizedKeysAcl

  $usingFallbackTask = $false
  try {
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service -Name sshd).Status -eq 'Running') {
      Restart-Service -Name sshd -Force
    } else {
      Start-Service -Name sshd
    }
  } catch {
    $report.initialServiceStartError = $_.Exception.Message
    Write-Warning 'The existing sshd service registration failed. Rebuilding it under LocalSystem...'
    try {
      Register-SshdService $sshdPath
      Start-Service -Name sshd
    } catch {
      $report.rebuiltServiceStartError = $_.Exception.Message
      Write-Warning 'The rebuilt service also failed. Starting the boot-time SYSTEM fallback task...'
      & "$env:WINDIR\System32\sc.exe" failure sshd reset= 0 actions= none/0 | Out-Null
      Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue
      $report.fallbackTask = Start-SshdFallbackTask $sshdPath $sshDataDirectory
      $usingFallbackTask = $true
    }
  }
  if (-not $usingFallbackTask) {
    (Get-Service -Name sshd).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
    Invoke-Checked "$env:WINDIR\System32\sc.exe" @(
      'failure', 'sshd', 'reset=', '86400', 'actions=', 'restart/5000/restart/5000/restart/5000'
    )
    Get-ScheduledTask -TaskName 'Local Receipt Printer SSH Listener' -ErrorAction SilentlyContinue |
      Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
  }

  $firewallName = 'LocalReceiptPrinter-OpenSSH-Mac'
  Get-NetFirewallRule -Name $firewallName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule `
    -Name $firewallName `
    -DisplayName 'OpenSSH from receipt-printer development Mac' `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -Action Allow `
    -LocalPort 22 `
    -RemoteAddress $MacAddress `
    -Profile Any | Out-Null

  if (-not (Test-LocalTcpPort 22)) {
    throw 'sshd reports Running, but TCP port 22 is not listening locally.'
  }

  $listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess)
  $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress -Unique)
  $profile = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias, NetworkCategory, IPv4Connectivity)

  $report.success = $true
  $report.launchMode = if ($usingFallbackTask) { 'ScheduledTaskFallback' } else { 'WindowsService' }
  $report.serviceStatus = (Get-Service -Name sshd).Status.ToString()
  $report.startType = (Get-CimInstance Win32_Service -Filter "Name='sshd'").StartMode
  $report.localPort22 = $true
  $report.listeners = $listeners
  $report.ipv4 = $addresses
  $report.networkProfiles = $profile
  $report.firewallRule = $firewallName
  $report.publicKeyInstalled = $true
} catch {
  $report.error = $_.Exception.Message
  $report.service = @(Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue |
    Select-Object Name, State, StartMode, ExitCode, ProcessId, StartName, PathName)
  $report.listeners = @(Get-NetTCPConnection -State Listen -LocalPort 22 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess)
  try {
    $report.openSshEvents = @(Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 8 -ErrorAction Stop |
      Select-Object TimeCreated, Id, LevelDisplayName, Message)
  } catch {}
  try {
    $report.serviceControlEvents = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'; StartTime = (Get-Date).AddMinutes(-10) } -MaxEvents 20 |
      Where-Object { $_.Message -match '(?i)sshd|OpenSSH SSH Server' } |
      Select-Object TimeCreated, Id, LevelDisplayName, Message)
  } catch {}
  if (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe')) {
    $report.foregroundDiagnostic = Get-SshdForegroundDiagnostic (Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe')
  }
} finally {
  $json = $report | ConvertTo-Json -Depth 6
  Write-Host ''
  Write-Host $json
  try {
    Invoke-WebRequest -Uri $ReportUrl -Method Post -ContentType 'application/json' -Body $json -UseBasicParsing -TimeoutSec 10 | Out-Null
  } catch {
    Write-Warning "Could not send the SSH diagnostic report to the Mac: $($_.Exception.Message)"
  }
}

if (-not $report.success) { exit 1 }
Write-Host ''
Write-Host 'SSH IS RUNNING AND THE MAC KEY IS INSTALLED.' -ForegroundColor Green
exit 0
