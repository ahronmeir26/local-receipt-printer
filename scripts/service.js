'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const action = process.argv[2];
if (!['install', 'uninstall'].includes(action)) {
  console.error('Usage: node scripts/service.js <install|uninstall>');
  process.exit(2);
}

const root = path.resolve(__dirname, '..');
const serverPath = path.join(root, 'src', 'server.js');
const label = 'com.localreceiptprinter.agent';

function run(command, args, options = {}) {
  const result = spawnSync(command, args, { stdio: options.quiet ? 'ignore' : 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  if (!options.allowFailure && result.status !== 0) throw new Error(`${command} exited with status ${result.status}`);
  return result;
}

function xml(value) {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
}

function installMac() {
  const agentsDirectory = path.join(os.homedir(), 'Library', 'LaunchAgents');
  const plistPath = path.join(agentsDirectory, `${label}.plist`);
  const logDirectory = path.join(os.homedir(), 'Library', 'Application Support', 'LocalReceiptPrinter');
  fs.mkdirSync(agentsDirectory, { recursive: true });
  fs.mkdirSync(logDirectory, { recursive: true });
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array><string>${xml(process.execPath)}</string><string>${xml(serverPath)}</string></array>
  <key>WorkingDirectory</key><string>${xml(root)}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>${xml(path.join(logDirectory, 'launchd.stdout.log'))}</string>
  <key>StandardErrorPath</key><string>${xml(path.join(logDirectory, 'launchd.stderr.log'))}</string>
</dict>
</plist>
`;
  fs.writeFileSync(plistPath, plist, { mode: 0o644 });
  const domain = `gui/${process.getuid()}`;
  run('/bin/launchctl', ['bootout', domain, plistPath], { quiet: true, allowFailure: true });
  run('/bin/launchctl', ['bootstrap', domain, plistPath]);
  run('/bin/launchctl', ['enable', `${domain}/${label}`]);
  run('/bin/launchctl', ['kickstart', '-k', `${domain}/${label}`]);
  console.log(`Installed and started ${label}. Open http://127.0.0.1:17890`);
}

function uninstallMac() {
  const plistPath = path.join(os.homedir(), 'Library', 'LaunchAgents', `${label}.plist`);
  run('/bin/launchctl', ['bootout', `gui/${process.getuid()}`, plistPath], { quiet: true, allowFailure: true });
  try { fs.unlinkSync(plistPath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  console.log(`Uninstalled ${label}. Logs and settings were kept.`);
}

function runWindows() {
  const args = [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', path.join(__dirname, 'windows-service.ps1'),
    '-Mode', action,
    '-NodePath', process.execPath,
    '-ServerPath', serverPath,
    '-WorkingDirectory', root,
  ];
  const optionalValues = [
    ['-WrapperPath', process.env.LOCAL_RECEIPT_PRINTER_SERVICE_WRAPPER],
    ['-DataDirectory', process.env.LOCAL_RECEIPT_PRINTER_DATA_DIR],
    ['-LogDirectory', process.env.LOCAL_RECEIPT_PRINTER_WRAPPER_LOG_DIR],
  ];
  for (const [name, value] of optionalValues) {
    if (value) args.push(name, value);
  }
  run('powershell.exe', args);
}

if (process.platform === 'darwin') {
  if (action === 'install') installMac(); else uninstallMac();
} else if (process.platform === 'win32') {
  runWindows();
} else {
  console.error('Automatic service installation currently supports macOS and Windows.');
  process.exit(1);
}
