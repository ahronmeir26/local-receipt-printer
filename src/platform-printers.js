'use strict';

const { execFile } = require('node:child_process');
const path = require('node:path');
const { promisify } = require('node:util');

const execFileAsync = promisify(execFile);
const WINDOWS_HELPER = path.join(__dirname, '..', 'scripts', 'windows-printer.ps1');

async function run(file, args, options = {}) {
  try {
    return await execFileAsync(file, args, {
      encoding: 'utf8',
      timeout: options.timeout || 15_000,
      windowsHide: true,
      maxBuffer: 4 * 1024 * 1024,
    });
  } catch (error) {
    const detail = (error.stderr || error.stdout || error.message || '').trim();
    const wrapped = new Error(detail || `${file} failed`);
    wrapped.code = error.code;
    throw wrapped;
  }
}

async function listMacPrinters() {
  let printersOutput = '';
  let devicesOutput = '';
  let defaultOutput = '';
  try {
    ({ stdout: printersOutput } = await run('/usr/bin/lpstat', ['-p']));
  } catch (error) {
    // CUPS returns an error when no printers exist; keep an empty list.
    if (!/no destinations added|no printers/i.test(error.message)) throw error;
  }
  try { ({ stdout: devicesOutput } = await run('/usr/bin/lpstat', ['-v'])); } catch {}
  try { ({ stdout: defaultOutput } = await run('/usr/bin/lpstat', ['-d'])); } catch {}

  const devices = new Map();
  for (const line of devicesOutput.split(/\r?\n/)) {
    const match = line.match(/^device for (.+?):\s*(.+)$/);
    if (match) devices.set(match[1], match[2]);
  }
  const defaultMatch = defaultOutput.match(/system default destination:\s*(.+)$/i);
  const defaultName = defaultMatch ? defaultMatch[1].trim() : null;

  return printersOutput.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^printer (\S+) (.+)$/);
    if (!match) return [];
    const statusText = match[2].trim();
    return [{
      name: match[1],
      isDefault: match[1] === defaultName,
      isOffline: /disabled|not available|offline/i.test(statusText),
      status: statusText,
      deviceUri: devices.get(match[1]) || null,
      driverName: null,
    }];
  });
}

async function listWindowsPrinters() {
  const { stdout } = await run('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', WINDOWS_HELPER, '-Mode', 'list',
  ], { timeout: 20_000 });
  if (!stdout.trim()) return [];
  const parsed = JSON.parse(stdout);
  return (Array.isArray(parsed) ? parsed : [parsed]).map((printer) => ({
    name: printer.Name,
    isDefault: Boolean(printer.Default),
    isOffline: Boolean(printer.WorkOffline),
    status: String(printer.Status || printer.PrinterStatus || 'Unknown'),
    deviceUri: printer.PortName || null,
    driverName: printer.DriverName || null,
  }));
}

async function listPrinters() {
  if (process.platform === 'darwin' || process.platform === 'linux') return listMacPrinters();
  if (process.platform === 'win32') return listWindowsPrinters();
  throw new Error(`Unsupported operating system: ${process.platform}`);
}

async function printMac(printerName, filePath) {
  const { stdout } = await run('/usr/bin/lp', ['-d', printerName, '-o', 'raw', filePath], { timeout: 30_000 });
  return stdout.trim();
}

async function printWindows(printerName, filePath) {
  const { stdout } = await run('powershell.exe', [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', WINDOWS_HELPER, '-Mode', 'print', '-PrinterName', printerName, '-FilePath', filePath,
  ], { timeout: 30_000 });
  return stdout.trim();
}

async function printFile(printerName, filePath) {
  if (process.platform === 'darwin' || process.platform === 'linux') return printMac(printerName, filePath);
  if (process.platform === 'win32') return printWindows(printerName, filePath);
  throw new Error(`Unsupported operating system: ${process.platform}`);
}

module.exports = { listPrinters, printFile };
