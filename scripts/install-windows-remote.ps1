param(
  [Parameter(Mandatory=$true)]
  [string]$ArchivePath,
  [string]$NodeVersion = '22.22.2',
  [string]$WinSWVersion = '2.12.0',
  [string]$ReportUrl = 'http://192.168.5.118:8765/report'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$winSWHash = 'B5066B7BBDFBA1293E5D15CDA3CAAEA88FBEAB35BD5B38C41C913D492AADFC4F'
$epsonApdHash = '107EDE9ABBFF09C2430E3E93F7F5AAA5E73FE9EA1B1AE091849398E014AF0297'
$currentStep = 'Starting installer'
$installReport = [ordered]@{
  type = 'printer-install'
  success = $false
  computer = $env:COMPUTERNAME
  username = $env:USERNAME
  identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  startedAt = [DateTime]::Now.ToString('o')
}

function Write-Step([string]$Message) {
  $script:currentStep = $Message
  Write-Host "`n==> $Message" -ForegroundColor Cyan
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

function Receive-VerifiedFile([string]$Uri, [string]$Destination, [string]$ExpectedHash) {
  Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing
  $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToUpperInvariant()
  if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
    throw "SHA-256 verification failed for $Uri."
  }
}

function Get-MatchingPrinters {
  return @(Get-CimInstance Win32_Printer | Where-Object {
    ($_.Name + ' ' + $_.DriverName) -match '(?i)TM[-_ ]?m30'
  })
}

function Refresh-EpsonUsbEnumeration([object[]]$Devices, [string]$PrinterHelper) {
  Write-Host 'Refreshing the Epson USB device and Windows Print Spooler...'
  foreach ($device in $Devices) {
    & "$env:WINDIR\System32\pnputil.exe" /restart-device $device.DeviceID | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "pnputil could not restart $($device.DeviceID) (status $LASTEXITCODE)." }
  }
  & "$env:WINDIR\System32\pnputil.exe" /scan-devices | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "pnputil hardware scan exited with status $LASTEXITCODE." }
  Restart-Service -Name Spooler -Force
  (Get-Service -Name Spooler).WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
  Start-Sleep -Seconds 5
  Invoke-Checked 'powershell.exe' @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PrinterHelper, '-Mode', 'ensure')
}

if (-not (Test-Administrator)) {
  throw 'Installation must run as Administrator so it can use Program Files and install the Windows service.'
}

$resolvedArchive = (Resolve-Path -LiteralPath $ArchivePath).Path
$installRoot = Join-Path $env:ProgramFiles 'LocalReceiptPrinter'
$releasesRoot = Join-Path $installRoot 'releases'
$runtimeRoot = Join-Path $installRoot 'runtime'
$serviceRoot = Join-Path $installRoot 'service'
$dataRoot = Join-Path $env:ProgramData 'LocalReceiptPrinter'
$wrapperLogsRoot = Join-Path $dataRoot 'wrapper-logs'
$temporaryRoot = Join-Path $env:TEMP "LocalReceiptPrinterInstall-$PID"
$releaseName = 'app-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$releasePath = Join-Path $releasesRoot $releaseName

try {
  Write-Step 'Preparing protected installation directories'
  New-Item -ItemType Directory -Force -Path $installRoot, $releasesRoot, $runtimeRoot, $serviceRoot, $dataRoot, $wrapperLogsRoot | Out-Null
  if (Test-Path -LiteralPath $temporaryRoot) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
  Expand-Archive -LiteralPath $resolvedArchive -DestinationPath $temporaryRoot -Force

  $packageFile = Get-ChildItem -Path $temporaryRoot -Filter package.json -Recurse -File |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'src\server.js') } |
    Select-Object -First 1
  if (-not $packageFile) { throw 'The archive does not contain the Local Receipt Printer application.' }

  New-Item -ItemType Directory -Path $releasePath | Out-Null
  Copy-Item -Path (Join-Path $packageFile.Directory.FullName '*') -Destination $releasePath -Recurse -Force

  Write-Step 'Installing a private verified Node.js runtime'
  $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
  $nodeFolderName = "node-v$NodeVersion-win-$architecture"
  $nodeInstallPath = Join-Path $runtimeRoot $nodeFolderName
  $nodePath = Join-Path $nodeInstallPath 'node.exe'
  if (-not (Test-Path -LiteralPath $nodePath)) {
    $nodeZipName = "$nodeFolderName.zip"
    $nodeZip = Join-Path $temporaryRoot $nodeZipName
    $checksumsPath = Join-Path $temporaryRoot 'SHASUMS256.txt'
    $nodeBaseUrl = "https://nodejs.org/dist/v$NodeVersion"
    Invoke-WebRequest -Uri "$nodeBaseUrl/$nodeZipName" -OutFile $nodeZip -UseBasicParsing
    Invoke-WebRequest -Uri "$nodeBaseUrl/SHASUMS256.txt" -OutFile $checksumsPath -UseBasicParsing
    $checksumLine = Get-Content -LiteralPath $checksumsPath |
      Where-Object { $_ -match "^[a-fA-F0-9]{64}\s+$([regex]::Escape($nodeZipName))$" } |
      Select-Object -First 1
    if (-not $checksumLine) { throw "No official checksum was found for $nodeZipName." }
    $expectedHash = ($checksumLine -split '\s+')[0].ToUpperInvariant()
    $actualHash = (Get-FileHash -LiteralPath $nodeZip -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $expectedHash) { throw 'The downloaded Node.js archive failed SHA-256 verification.' }
    Expand-Archive -LiteralPath $nodeZip -DestinationPath $runtimeRoot -Force
  }

  Write-Step 'Installing the verified Windows service wrapper'
  $wrapperPath = Join-Path $serviceRoot 'LocalReceiptPrinterService.exe'
  $wrapperIsValid = (
    (Test-Path -LiteralPath $wrapperPath) -and
    ((Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash.ToUpperInvariant() -eq $winSWHash)
  )
  if (-not $wrapperIsValid) {
    $wrapperDownload = Join-Path $temporaryRoot 'WinSW.NET461.exe'
    Receive-VerifiedFile `
      -Uri "https://github.com/winsw/winsw/releases/download/v$WinSWVersion/WinSW.NET461.exe" `
      -Destination $wrapperDownload `
      -ExpectedHash $winSWHash
    Copy-Item -LiteralPath $wrapperDownload -Destination $wrapperPath -Force
  }

  Write-Step 'Running application tests'
  Push-Location $releasePath
  try {
    Invoke-Checked $nodePath @('--test')
    Invoke-Checked $nodePath @('--check', 'src\server.js')
    Invoke-Checked $nodePath @('--check', 'src\printer-manager.js')
    Invoke-Checked $nodePath @('--check', 'src\platform-printers.js')
    Invoke-Checked $nodePath @('--check', 'public\app.js')
  } finally {
    Pop-Location
  }

  Write-Step 'Detecting and repairing the TM-m30III USB printer queue'
  $printerHelper = Join-Path $releasePath 'scripts\windows-printer.ps1'
  $epsonUsbDevices = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
    $_.DeviceID -match '(?i)^USB\\VID_04B8&PID_(0E32|0202)' -and
    $_.ConfigManagerErrorCode -eq 0
  })
  if ($epsonUsbDevices.Count -eq 0) {
    throw 'The TM-m30III is not visible over USB. Connect its USB-B computer cable, turn it on, and rerun the installer.'
  }
  Invoke-Checked 'powershell.exe' @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $printerHelper, '-Mode', 'ensure')
  $matchingPrinters = @(Get-MatchingPrinters)

  if ($matchingPrinters.Count -eq 0) {
    Refresh-EpsonUsbEnumeration $epsonUsbDevices $printerHelper
    $matchingPrinters = @(Get-MatchingPrinters)
  }

  if ($matchingPrinters.Count -eq 0) {
    Write-Host 'Windows sees the Epson USB hardware, but no dependable printer queue exists.' -ForegroundColor Yellow
    Write-Host 'Starting Epson APD6 once so the official TM-m30III USB queue can be registered.' -ForegroundColor Yellow
    $epsonInstaller = Join-Path $temporaryRoot 'APD_612_m30III_WM.exe'
    Receive-VerifiedFile `
      -Uri 'https://ftp.epson.com/drivers/pos/APD_612_m30III_WM.exe' `
      -Destination $epsonInstaller `
      -ExpectedHash $epsonApdHash
    $signature = Get-AuthenticodeSignature -LiteralPath $epsonInstaller
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?i)Epson') {
      throw 'The Epson APD6 installer did not have a valid Epson Authenticode signature.'
    }
    $driverInstall = Start-Process -FilePath $epsonInstaller -Wait -PassThru
    if ($driverInstall.ExitCode -ne 0) { throw "Epson APD6 exited with status $($driverInstall.ExitCode)." }

    Refresh-EpsonUsbEnumeration $epsonUsbDevices $printerHelper
    $matchingPrinters = @(Get-MatchingPrinters)
  }

  if ($matchingPrinters.Count -eq 0) {
    throw 'The Epson installer completed, but no TM-m30III queue exists. Rerun APD6 and add the connected USB printer.'
  }
  $onlinePrinters = @($matchingPrinters | Where-Object { -not $_.WorkOffline })
  $selectedPrinter = if ($onlinePrinters.Count -eq 1) {
    $onlinePrinters[0]
  } elseif ($matchingPrinters.Count -eq 1) {
    $matchingPrinters[0]
  } else {
    $matchingPrinters | Where-Object { $_.Name -eq 'EPSON TM-m30III USB' } | Select-Object -First 1
  }
  if (-not $selectedPrinter) {
    throw 'Multiple Epson TM-m30 queues exist and no unique connected queue can be selected safely.'
  }
  Write-Host "Selected USB printer queue: $($selectedPrinter.Name)"

  Write-Step 'Migrating and pinning printer settings'
  $configPath = Join-Path $dataRoot 'config.json'
  $legacyConfigPath = Join-Path (Join-Path $env:LOCALAPPDATA 'LocalReceiptPrinter') 'config.json'
  if (-not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $legacyConfigPath)) {
    Copy-Item -LiteralPath $legacyConfigPath -Destination $configPath
  }
  $config = @{}
  if (Test-Path -LiteralPath $configPath) {
    try {
      $storedConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
      foreach ($property in $storedConfig.PSObject.Properties) { $config[$property.Name] = $property.Value }
    } catch {
      Write-Warning 'The previous configuration was invalid and will be replaced.'
    }
  }
  $config.host = '127.0.0.1'
  $config.port = 17890
  $config.printerName = $selectedPrinter.Name
  $config.printerMatch = 'TM-m30'
  [IO.File]::WriteAllText($configPath, (($config | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))

  Write-Step 'Installing the automatic boot-time Windows service'
  $env:LOCAL_RECEIPT_PRINTER_SERVICE_WRAPPER = $wrapperPath
  $env:LOCAL_RECEIPT_PRINTER_DATA_DIR = $dataRoot
  $env:LOCAL_RECEIPT_PRINTER_WRAPPER_LOG_DIR = $wrapperLogsRoot
  Push-Location $releasePath
  try {
    Invoke-Checked $nodePath @('scripts\service.js', 'install')
  } finally {
    Pop-Location
  }

  Write-Step 'Verifying the service and selected USB printer'
  $health = $null
  for ($attempt = 1; $attempt -le 30; $attempt += 1) {
    try {
      $health = Invoke-RestMethod -Uri 'http://127.0.0.1:17890/api/health' -TimeoutSec 2
      if ($health.ok) { break }
    } catch {
      Start-Sleep -Seconds 1
    }
  }
  if (-not $health.ok) { throw 'The Windows service is running, but its local health check did not succeed.' }

  $status = Invoke-RestMethod -Uri 'http://127.0.0.1:17890/api/status' -TimeoutSec 20
  if (-not $status.selectedPrinter) { throw "The service is healthy but did not select a printer: $($status.selectionReason)" }
  if ($status.selectedPrinter.isOffline) { throw "The selected printer is offline: $($status.selectedPrinter.name)" }

  Write-Step 'Printing a physical USB verification receipt'
  $testBody = @{
    text = "LOCAL RECEIPT PRINTER`nUSB connection verified`n$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))`n"
    copies = 1
    cut = $true
    openDrawer = $false
  } | ConvertTo-Json
  $testResult = Invoke-RestMethod `
    -Uri 'http://127.0.0.1:17890/api/print' `
    -Method Post `
    -ContentType 'application/json' `
    -Body $testBody `
    -TimeoutSec 90
  if ($testResult.job.status -ne 'accepted-by-spooler') { throw 'The verification receipt was not accepted by the Windows spooler.' }

  Write-Host ''
  Write-Host 'Local Receipt Printer installation completed.' -ForegroundColor Green
  Write-Host "Installed app: $releasePath"
  Write-Host "Node runtime: $nodePath"
  Write-Host "Windows service: LocalReceiptPrinter"
  Write-Host "Selected printer: $($status.selectedPrinter.name)"
  Write-Host 'Website: http://127.0.0.1:17890'
  Write-Host 'A USB verification receipt was submitted. Confirm that paper physically printed.'
  $installReport.success = $true
  $installReport.completedAt = [DateTime]::Now.ToString('o')
  $installReport.releasePath = $releasePath
  $installReport.service = 'LocalReceiptPrinter'
  $installReport.printer = $status.selectedPrinter
  $installReport.testJob = $testResult.job
} catch {
  $installReport.step = $currentStep
  $installReport.error = $_.Exception.Message
  $installReport.exceptionType = $_.Exception.GetType().FullName
  $installReport.scriptStackTrace = $_.ScriptStackTrace
  $installReport.completedAt = [DateTime]::Now.ToString('o')
  $installReport.windowsService = @(Get-CimInstance Win32_Service -Filter "Name='LocalReceiptPrinter'" -ErrorAction SilentlyContinue |
    Select-Object Name, State, StartMode, ExitCode, ProcessId, StartName, PathName)
  $installReport.printers = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue |
    Select-Object Name, WorkOffline, Status, PrinterStatus, PortName, DriverName)
  $serviceLogPath = Join-Path $dataRoot 'service.log'
  if (Test-Path -LiteralPath $serviceLogPath) {
    $installReport.serviceLogTail = @(Get-Content -LiteralPath $serviceLogPath -Tail 40 -ErrorAction SilentlyContinue)
  }
  throw
} finally {
  try {
    $reportJson = $installReport | ConvertTo-Json -Depth 8
    Invoke-WebRequest -Uri $ReportUrl -Method Post -ContentType 'application/json' -Body $reportJson -UseBasicParsing -TimeoutSec 10 | Out-Null
  } catch {
    Write-Warning "Could not send the installation report to the Mac: $($_.Exception.Message)"
  }
  if (Test-Path -LiteralPath $temporaryRoot) {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
