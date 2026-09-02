param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('install', 'uninstall')]
  [string]$Mode,
  [Parameter(Mandatory=$true)]
  [string]$NodePath,
  [Parameter(Mandatory=$true)]
  [string]$ServerPath,
  [Parameter(Mandatory=$true)]
  [string]$WorkingDirectory,
  [string]$WrapperPath,
  [string]$DataDirectory,
  [string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
$serviceName = 'LocalReceiptPrinter'
$displayName = 'Local Receipt Printer'
$legacyTaskName = 'Local Receipt Printer'
$kioskExitExecutableName = 'LocalReceiptPrinterKioskExit.exe'

function Test-Administrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [Security.Principal.WindowsPrincipal]::new($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-XmlText([string]$Value) {
  return [Security.SecurityElement]::Escape($Value)
}

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Executable exited with status $LASTEXITCODE."
  }
}

function Remove-LegacyTask {
  Stop-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue
  Get-ScheduledTask -TaskName $legacyTaskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
}

function Remove-ExistingService {
  $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  if (-not $service) { return }
  if ($service.Status -ne 'Stopped') {
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
  }
  Invoke-Checked "$env:WINDIR\System32\sc.exe" @('delete', $serviceName)
  for ($attempt = 0; $attempt -lt 20; $attempt += 1) {
    if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) { return }
    Start-Sleep -Milliseconds 250
  }
  throw "The previous $displayName service is still pending deletion."
}

function Install-KioskExitHelper([string]$SourcePath, [string]$DestinationPath) {
  if (-not (Test-Path -LiteralPath $SourcePath)) {
    throw "Windows kiosk-exit helper source is missing: $SourcePath"
  }
  $framework64Compiler = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
  $frameworkCompiler = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
  $compiler = if (Test-Path -LiteralPath $framework64Compiler) {
    $framework64Compiler
  } elseif (Test-Path -LiteralPath $frameworkCompiler) {
    $frameworkCompiler
  } else {
    $null
  }
  if (-not $compiler) {
    throw 'The Windows .NET Framework C# compiler required for the kiosk-exit helper was not found.'
  }

  Invoke-Checked $compiler @(
    '/nologo',
    '/target:exe',
    "/out:$DestinationPath",
    $SourcePath
  )
  Write-Output "Installed the Windows kiosk-exit helper at $DestinationPath."
}

if (-not (Test-Administrator)) {
  throw "$displayName service installation requires an Administrator PowerShell session."
}

if (-not $WrapperPath) { $WrapperPath = Join-Path $env:ProgramFiles 'LocalReceiptPrinter\service\LocalReceiptPrinterService.exe' }
if (-not $DataDirectory) { $DataDirectory = Join-Path $env:ProgramData 'LocalReceiptPrinter' }
if (-not $LogDirectory) { $LogDirectory = Join-Path $DataDirectory 'wrapper-logs' }
$kioskExitExecutablePath = Join-Path (Split-Path -Parent $WrapperPath) $kioskExitExecutableName

if ($Mode -eq 'uninstall') {
  Remove-ExistingService
  Remove-LegacyTask
  Remove-Item -LiteralPath $kioskExitExecutablePath -Force -ErrorAction SilentlyContinue
  Write-Output "Uninstalled $displayName. Settings and logs were kept."
  exit 0
}

$resolvedNode = (Resolve-Path -LiteralPath $NodePath).Path
$resolvedServer = (Resolve-Path -LiteralPath $ServerPath).Path
$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$resolvedWrapper = (Resolve-Path -LiteralPath $WrapperPath).Path
$configurationPath = [IO.Path]::ChangeExtension($resolvedWrapper, '.xml')
New-Item -ItemType Directory -Force -Path $DataDirectory, $LogDirectory | Out-Null
$kioskExitSourcePath = Join-Path $resolvedWorkingDirectory 'scripts\windows-kiosk-exit.cs'
$kioskExitExecutablePath = Join-Path (Split-Path -Parent $resolvedWrapper) $kioskExitExecutableName
Install-KioskExitHelper $kioskExitSourcePath $kioskExitExecutablePath

$nodeXml = ConvertTo-XmlText $resolvedNode
$serverXml = ConvertTo-XmlText $resolvedServer
$workingXml = ConvertTo-XmlText $resolvedWorkingDirectory
$dataXml = ConvertTo-XmlText $DataDirectory
$logsXml = ConvertTo-XmlText $LogDirectory
$kioskExitXml = ConvertTo-XmlText $kioskExitExecutablePath
$configuration = @"
<service>
  <id>$serviceName</id>
  <name>$displayName</name>
  <description>Reliable localhost ESC/POS bridge for the Epson TM-m30III USB receipt printer.</description>
  <executable>$nodeXml</executable>
  <arguments>&quot;$serverXml&quot;</arguments>
  <workingdirectory>$workingXml</workingdirectory>
  <env name="NODE_ENV" value="production"/>
  <env name="LOCAL_RECEIPT_PRINTER_DATA_DIR" value="$dataXml"/>
  <env name="LOCAL_RECEIPT_PRINTER_HOST" value="127.0.0.1"/>
  <env name="LOCAL_RECEIPT_PRINTER_KIOSK_EXIT_PATH" value="$kioskExitXml"/>
  <startmode>Automatic</startmode>
  <delayedAutoStart>false</delayedAutoStart>
  <onfailure action="restart" delay="5 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$logsXml</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>5120</sizeThreshold>
    <keepFiles>4</keepFiles>
  </log>
</service>
"@
[IO.File]::WriteAllText($configurationPath, $configuration, [Text.UTF8Encoding]::new($false))

Remove-LegacyTask
Remove-ExistingService
Invoke-Checked $resolvedWrapper @('install')
Invoke-Checked "$env:WINDIR\System32\sc.exe" @('failureflag', $serviceName, '1')
Invoke-Checked $resolvedWrapper @('start')

$installed = Get-Service -Name $serviceName
$installed.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
Write-Output "Installed and started $displayName as an automatic boot-time Windows service."
Write-Output 'The service stays independent of Print Spooler restarts and restarts five seconds after its own failure.'
Write-Output 'The loopback kiosk-exit endpoint can sign out the active Windows console session.'
Write-Output 'Open http://127.0.0.1:17890'
