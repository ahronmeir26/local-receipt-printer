param(
  [Parameter(Mandatory=$true)]
  [string]$PublicKeyPath,
  [string]$MacAddress = '192.168.5.118',
  [string]$ReportUrl = 'http://192.168.5.118:8765/report',
  [string]$SourceUrl = 'http://192.168.5.118:8765'
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$repairPath = Join-Path $env:TEMP 'LocalReceiptPrinterSshRepair.ps1'

for ($attempt = 1; $attempt -le 240; $attempt += 1) {
  Write-Host "`nSSH repair attempt $attempt. Downloading the latest repair from the Mac..." -ForegroundColor Cyan
  try {
    Invoke-WebRequest -Uri "$SourceUrl/q" -OutFile $repairPath -UseBasicParsing -TimeoutSec 15
    & powershell.exe `
      -NoLogo `
      -NoProfile `
      -ExecutionPolicy Bypass `
      -File $repairPath `
      -PublicKeyPath $PublicKeyPath `
      -MacAddress $MacAddress `
      -ReportUrl $ReportUrl
    if ($LASTEXITCODE -eq 0) {
      Write-Host 'SSH repair succeeded. Continuing the printer installation.' -ForegroundColor Green
      exit 0
    }
  } catch {
    $message = "SSH bootstrap attempt $attempt failed before the repair ran: $($_.Exception.Message)"
    Write-Warning $message
    try {
      Invoke-WebRequest -Uri $ReportUrl -Method Post -ContentType 'text/plain' -Body $message -UseBasicParsing -TimeoutSec 10 | Out-Null
    } catch {}
  }

  Write-Host 'The error was reported automatically. Retrying with the latest repair in 15 seconds...'
  Start-Sleep -Seconds 15
}

Write-Error 'SSH could not be repaired after one hour of automatic attempts.'
exit 1
