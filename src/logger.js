'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { ensureDataDirectory } = require('./config');

const MAX_LOG_BYTES = 5 * 1024 * 1024;
const logPath = path.join(ensureDataDirectory(), 'service.log');

function rotateIfNeeded() {
  try {
    if (fs.statSync(logPath).size < MAX_LOG_BYTES) return;
    const previous = `${logPath}.1`;
    try { fs.unlinkSync(previous); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    fs.renameSync(logPath, previous);
  } catch (error) {
    if (error.code !== 'ENOENT') console.error('Log rotation failed:', error.message);
  }
}

function write(level, message, details) {
  const record = {
    time: new Date().toISOString(),
    level,
    message,
    ...(details === undefined ? {} : { details }),
  };
  const line = `${JSON.stringify(record)}\n`;
  process.stdout.write(line);
  try {
    rotateIfNeeded();
    fs.appendFileSync(logPath, line, { mode: 0o600 });
  } catch (error) {
    console.error('Log write failed:', error.message);
  }
}

module.exports = {
  info: (message, details) => write('info', message, details),
  warn: (message, details) => write('warn', message, details),
  error: (message, details) => write('error', message, details),
  logPath,
};
