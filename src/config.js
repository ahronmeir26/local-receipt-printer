'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const APP_ID = 'LocalReceiptPrinter';
const DEFAULT_CONFIG = Object.freeze({
  host: '127.0.0.1',
  port: 17890,
  printerName: null,
  printerMatch: 'TM-m30',
});

function dataDirectory() {
  if (process.env.LOCAL_RECEIPT_PRINTER_DATA_DIR) {
    return path.resolve(process.env.LOCAL_RECEIPT_PRINTER_DATA_DIR);
  }

  if (process.platform === 'win32') {
    return path.join(process.env.LOCALAPPDATA || os.homedir(), APP_ID);
  }

  if (process.platform === 'darwin') {
    return path.join(os.homedir(), 'Library', 'Application Support', APP_ID);
  }

  return path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state'), APP_ID);
}

function ensureDataDirectory() {
  const directory = dataDirectory();
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  return directory;
}

function configPath() {
  return path.join(ensureDataDirectory(), 'config.json');
}

function loadConfig() {
  let stored = {};
  try {
    stored = JSON.parse(fs.readFileSync(configPath(), 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const portFromEnvironment = Number.parseInt(process.env.LOCAL_RECEIPT_PRINTER_PORT || '', 10);
  return {
    ...DEFAULT_CONFIG,
    ...stored,
    host: process.env.LOCAL_RECEIPT_PRINTER_HOST || stored.host || DEFAULT_CONFIG.host,
    port: Number.isInteger(portFromEnvironment) ? portFromEnvironment : (stored.port || DEFAULT_CONFIG.port),
  };
}

function saveConfig(config) {
  const destination = configPath();
  const temporary = `${destination}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, destination);
}

module.exports = { APP_ID, DEFAULT_CONFIG, configPath, dataDirectory, ensureDataDirectory, loadConfig, saveConfig };
