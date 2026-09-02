param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('list', 'print', 'ensure')]
  [string]$Mode,
  [string]$PrinterName,
  [string]$FilePath
)

$ErrorActionPreference = 'Stop'
$queueName = 'EPSON TM-m30III USB'

function Get-LocalPrinters {
  return @(Get-CimInstance Win32_Printer | Select-Object Name, Default, WorkOffline, Status, PrinterStatus, PortName, DriverName)
}

function Get-MatchingPrinters {
  return @(Get-LocalPrinters | Where-Object {
    ($_.Name + ' ' + $_.DriverName) -match '(?i)TM[-_ ]?m30'
  })
}

function Get-PresentTmM30UsbDevices {
  return @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
    $_.DeviceID -match '(?i)^USB\\VID_04B8&PID_(0E32|0202)' -and
    $_.ConfigManagerErrorCode -eq 0
  })
}

function Get-PresentTmM30UsbPorts {
  $ports = @()
  $printerDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    $_.InstanceId -match '(?i)^USBPRINT\\'
  })

  foreach ($device in $printerDevices) {
    $parentId = $null
    try {
      $parentId = (Get-PnpDeviceProperty `
        -InstanceId $device.InstanceId `
        -KeyName 'DEVPKEY_Device_Parent' `
        -ErrorAction Stop).Data
    } catch {}

    $isTmM30 = (
      (($device.FriendlyName + ' ' + $device.InstanceId) -match '(?i)TM[-_ ]?m30') -or
      ($parentId -match '(?i)^USB\\VID_04B8&PID_(0E32|0202)')
    )
    if (-not $isTmM30) { continue }

    $registryPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\' + $device.InstanceId + '\Device Parameters'
    try {
      $portName = (Get-ItemProperty -LiteralPath $registryPath -Name PortName -ErrorAction Stop).PortName
      if ($portName -match '^USB\d+$') { $ports += $portName }
    } catch {}
  }

  return @($ports | Select-Object -Unique)
}

function Ensure-TmM30Queue {
  $matching = @(Get-MatchingPrinters)
  $epsonUsbDevices = @(Get-PresentTmM30UsbDevices)
  if ($epsonUsbDevices.Count -eq 0) { return @() }

  $presentPorts = @(Get-PresentTmM30UsbPorts)
  $managedQueue = $matching | Where-Object { $_.Name -eq $queueName } | Select-Object -First 1
  if ($managedQueue -and $presentPorts.Count -eq 1 -and $managedQueue.PortName -ne $presentPorts[0]) {
    Set-Printer -Name $managedQueue.Name -PortName $presentPorts[0]
    $matching = @(Get-MatchingPrinters)
  }
  if ($matching.Count -gt 0) { return $matching }

  $usbPorts = @(Get-PrinterPort -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^USB\d+$' })
  $assignedPorts = @(Get-LocalPrinters | Select-Object -ExpandProperty PortName -Unique)
  $unassignedPorts = @($usbPorts | Where-Object { $assignedPorts -notcontains $_.Name })
  $candidatePort = if ($presentPorts.Count -eq 1) {
    $presentPorts[0]
  } elseif ($unassignedPorts.Count -eq 1) {
    $unassignedPorts[0].Name
  } elseif ($usbPorts.Count -eq 1) {
    $usbPorts[0].Name
  } else {
    $null
  }
  if (-not $candidatePort) { return @() }

  $driver = Get-PrinterDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(?i)TM[-_ ]?m30.*III|EPSON.*m30' } |
    Select-Object -First 1
  if (-not $driver) {
    Add-PrinterDriver -Name 'Generic / Text Only' -ErrorAction SilentlyContinue
    $driver = Get-PrinterDriver -Name 'Generic / Text Only' -ErrorAction SilentlyContinue
  }
  if (-not $driver) {
    $printUiArguments = 'printui.dll,PrintUIEntry /ia /m "Generic / Text Only" /h "x64" /v "Type 3 - User Mode" /f "' + (Join-Path $env:WINDIR 'inf\ntprint.inf') + '"'
    $driverInstall = Start-Process `
      -FilePath (Join-Path $env:WINDIR 'System32\rundll32.exe') `
      -ArgumentList $printUiArguments `
      -Wait `
      -PassThru
    if ($driverInstall.ExitCode -eq 0) {
      $driver = Get-PrinterDriver -Name 'Generic / Text Only' -ErrorAction SilentlyContinue
    }
  }
  if (-not $driver) { return @() }

  if (-not (Get-Printer -Name $queueName -ErrorAction SilentlyContinue)) {
    Add-Printer -Name $queueName -DriverName $driver.Name -PortName $candidatePort
  }
  return @(Get-MatchingPrinters)
}

if ($Mode -eq 'ensure') {
  @(Ensure-TmM30Queue) | ConvertTo-Json -Compress
  exit 0
}

if ($Mode -eq 'list') {
  try { $null = Ensure-TmM30Queue } catch {
    [Console]::Error.WriteLine("Automatic TM-m30III queue check failed: $($_.Exception.Message)")
  }
  @(Get-LocalPrinters) | ConvertTo-Json -Compress
  exit 0
}

if ([string]::IsNullOrWhiteSpace($PrinterName)) { throw 'PrinterName is required.' }
if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path -LiteralPath $FilePath)) { throw 'FilePath does not exist.' }

$source = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class RawPrinter {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private class DOC_INFO_1 {
        [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
        [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
        [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
    }

    [DllImport("winspool.drv", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool OpenPrinter(string printerName, out IntPtr printer, IntPtr defaults);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool ClosePrinter(IntPtr printer);
    [DllImport("winspool.drv", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern int StartDocPrinter(IntPtr printer, int level, [In] DOC_INFO_1 docInfo);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool EndDocPrinter(IntPtr printer);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool StartPagePrinter(IntPtr printer);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool EndPagePrinter(IntPtr printer);
    [DllImport("winspool.drv", SetLastError = true)]
    private static extern bool WritePrinter(IntPtr printer, byte[] bytes, int count, out int written);

    public static int Send(string printerName, byte[] bytes) {
        IntPtr printer;
        if (!OpenPrinter(printerName, out printer, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            var info = new DOC_INFO_1 { pDocName = "Local Receipt Printer", pDataType = "RAW" };
            int jobId = StartDocPrinter(printer, 1, info);
            if (jobId == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                if (!StartPagePrinter(printer)) throw new Win32Exception(Marshal.GetLastWin32Error());
                try {
                    int written;
                    if (!WritePrinter(printer, bytes, bytes.Length, out written)) throw new Win32Exception(Marshal.GetLastWin32Error());
                    if (written != bytes.Length) throw new Exception("Only " + written + " of " + bytes.Length + " bytes were written.");
                } finally { EndPagePrinter(printer); }
            } finally { EndDocPrinter(printer); }
            return jobId;
        } finally { ClosePrinter(printer); }
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp
$bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $FilePath))
$jobId = [RawPrinter]::Send($PrinterName, $bytes)
Write-Output "Windows spooler job $jobId"
