'use strict';

const path = require('node:path');
const { execFile } = require('node:child_process');

const DEFAULT_COOLDOWN_MS = 5_000;
const KIOSK_EXIT_TIMEOUT_MS = 15_000;

function defaultKioskExitPath() {
  const programFiles = process.env.ProgramFiles || 'C:\\Program Files';
  return path.join(programFiles, 'LocalReceiptPrinter', 'service', 'LocalReceiptPrinterKioskExit.exe');
}

function signOutActiveKioskSession() {
  const executable = process.env.LOCAL_RECEIPT_PRINTER_KIOSK_EXIT_PATH || defaultKioskExitPath();
  return new Promise((resolve, reject) => {
    execFile(
      executable,
      [],
      { encoding: 'utf8', timeout: KIOSK_EXIT_TIMEOUT_MS, windowsHide: true },
      (error, stdout, stderr) => {
        if (error) {
          const detail = String(stderr || stdout || error.message).trim();
          reject(new Error(detail || error.message));
          return;
        }
        const sessionId = Number.parseInt(String(stdout || '').trim(), 10);
        if (!Number.isInteger(sessionId) || sessionId < 1) {
          reject(new Error('The Windows kiosk-exit helper returned an invalid console session ID.'));
          return;
        }
        resolve(sessionId);
      },
    );
  });
}

class WindowsKioskController {
  constructor(options = {}) {
    this.platform = options.platform || process.platform;
    this.signOutSession = options.signOutSession || signOutActiveKioskSession;
    this.now = options.now || Date.now;
    this.cooldownMs = options.cooldownMs || DEFAULT_COOLDOWN_MS;
    this.lastRequestedAt = 0;
    this.requestInFlight = null;
  }

  async exitKiosk() {
    if (this.platform !== 'win32') {
      throw Object.assign(new Error('Kiosk exit is available only on Windows.'), { statusCode: 501 });
    }
    if (this.requestInFlight) {
      throw Object.assign(new Error('A kiosk exit request is already in progress.'), { statusCode: 409 });
    }

    const requestedAt = this.now();
    if (this.lastRequestedAt && requestedAt - this.lastRequestedAt < this.cooldownMs) {
      throw Object.assign(new Error('Kiosk exit requests are limited to one every five seconds.'), { statusCode: 429 });
    }
    this.lastRequestedAt = requestedAt;

    this.requestInFlight = this.signOutSession();
    try {
      const sessionId = await this.requestInFlight;
      return {
        action: 'exit-kiosk',
        status: 'completed',
        sessionId,
        requestedAt: new Date(requestedAt).toISOString(),
      };
    } catch (error) {
      throw Object.assign(
        new Error(error instanceof Error ? error.message : String(error)),
        { statusCode: 500 },
      );
    } finally {
      this.requestInFlight = null;
    }
  }
}

module.exports = { DEFAULT_COOLDOWN_MS, WindowsKioskController, defaultKioskExitPath, signOutActiveKioskSession };
