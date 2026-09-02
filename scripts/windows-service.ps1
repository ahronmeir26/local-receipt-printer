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

if (-not (Test-Administrator)) {
  throw "$displayName service installation requires an Administrator PowerShell session."
}

if (-not $WrapperPath) { $WrapperPath = Join-Path $env:ProgramFiles 'LocalReceiptPrinter\service\LocalReceiptPrinterService.exe' }
if (-not $DataDirectory) { $DataDirectory = Join-Path $env:ProgramData 'LocalReceiptPrinter' }
if (-not $LogDirectory) { $LogDirectory = Join-Path $DataDirectory 'wrapper-logs' }

if ($Mode -eq 'uninstall') {
  Remove-ExistingService
  Remove-LegacyTask
  Write-Output "Uninstalled $displayName. Settings and logs were kept."
  exit 0
}

$resolvedNode = (Resolve-Path -LiteralPath $NodePath).Path
$resolvedServer = (Resolve-Path -LiteralPath $ServerPath).Path
$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$resolvedWrapper = (Resolve-Path -LiteralPath $WrapperPath).Path
$configurationPath = [IO.Path]::ChangeExtension($resolvedWrapper, '.xml')
New-Item -ItemType Directory -Force -Path $DataDirectory, $LogDirectory | Out-Null

$nodeXml = ConvertTo-XmlText $resolvedNode
$serverXml = ConvertTo-XmlText $resolvedServer
$workingXml = ConvertTo-XmlText $resolvedWorkingDirectory
$dataXml = ConvertTo-XmlText $DataDirectory
$logsXml = ConvertTo-XmlText $LogDirectory
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
Write-Output 'Open http://127.0.0.1:17890'
