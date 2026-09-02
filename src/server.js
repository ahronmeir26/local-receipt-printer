'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { loadConfig, configPath } = require('./config');
const { applyCorsHeaders, handlePreflight, originIsAllowed } = require('./cors');
const { textReceipt } = require('./escpos');
const logger = require('./logger');
const { PrinterManager } = require('./printer-manager');
const { WindowsKioskController } = require('./windows-kiosk');
const packageJson = require('../package.json');

const config = loadConfig();
const manager = new PrinterManager(config);
const kioskController = new WindowsKioskController();
const publicDirectory = path.join(__dirname, '..', 'public');
const MAX_REQUEST_BYTES = 3 * 1024 * 1024;
const startedAt = Date.now();

const staticFiles = {
  '/': ['index.html', 'text/html; charset=utf-8'],
  '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
  '/styles.css': ['styles.css', 'text/css; charset=utf-8'],
};

function sendJson(response, statusCode, value) {
  const body = JSON.stringify(value);
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  response.end(body);
}

function sendStatic(response, route) {
  const [fileName, contentType] = staticFiles[route];
  const body = fs.readFileSync(path.join(publicDirectory, fileName));
  response.writeHead(200, {
    'Content-Type': contentType,
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    'Content-Security-Policy': "default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'",
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
  });
  response.end(body);
}

async function readJson(request) {
  if (!String(request.headers['content-type'] || '').toLowerCase().startsWith('application/json')) {
    const error = new Error('Content-Type must be application/json.');
    error.statusCode = 415;
    throw error;
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_REQUEST_BYTES) {
      const error = new Error('Request body is too large.');
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    const error = new Error('Request body is not valid JSON.');
    error.statusCode = 400;
    throw error;
  }
}

async function handleApi(request, response, pathname) {
  if (!originIsAllowed(request.headers.origin)) return sendJson(response, 403, { ok: false, error: 'Cross-origin requests are not allowed.' });
  applyCorsHeaders(request, response);

  if (request.method === 'OPTIONS') {
    if (handlePreflight(request, response)) return;
    return sendJson(response, 403, { ok: false, error: 'That cross-origin request is not allowed.' });
  }

  if (request.method === 'GET' && pathname === '/api/health') {
    return sendJson(response, 200, {
      ok: true,
      version: packageJson.version,
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
    });
  }

  if (request.method === 'GET' && (pathname === '/api/status' || pathname === '/api/printers')) {
    const discovery = await manager.discover();
    return sendJson(response, 200, {
      ok: true,
      version: packageJson.version,
      uptimeSeconds: Math.floor((Date.now() - startedAt) / 1000),
      queueDepth: manager.queueDepth,
      lastJob: manager.lastJob,
      config: { printerName: config.printerName, printerMatch: config.printerMatch, configPath: configPath() },
      ...discovery,
    });
  }

  if (request.method === 'POST' && pathname === '/api/config') {
    const body = await readJson(request);
    if (body.printerName !== null && typeof body.printerName !== 'string') throw Object.assign(new Error('printerName must be a string or null.'), { statusCode: 400 });
    const discovery = await manager.discover();
    if (body.printerName && !discovery.printers.some((printer) => printer.name === body.printerName)) {
      throw Object.assign(new Error('That printer is not currently installed.'), { statusCode: 400 });
    }
    manager.setPrinter(body.printerName || null);
    const updated = await manager.discover();
    return sendJson(response, 200, { ok: true, ...updated });
  }

  if (request.method === 'POST' && pathname === '/api/windows/kiosk-exit') {
    const body = await readJson(request);
    if (!body || body.action !== 'exit-kiosk' || Object.keys(body).length !== 1) {
      throw Object.assign(new Error('action must be exactly "exit-kiosk".'), { statusCode: 400 });
    }
    logger.warn('Windows kiosk exit requested');
    const result = await kioskController.exitKiosk();
    logger.warn('Windows kiosk exit completed', result);
    return sendJson(response, 202, { ok: true, ...result });
  }

  if (request.method === 'POST' && pathname === '/api/print') {
    const body = await readJson(request);
    if (typeof body.text !== 'string' || body.text.length === 0) throw Object.assign(new Error('text is required.'), { statusCode: 400 });
    if (Buffer.byteLength(body.text, 'utf8') > 1024 * 1024) throw Object.assign(new Error('text exceeds the 1 MB limit.'), { statusCode: 400 });
    const result = await manager.enqueue(textReceipt({ text: body.text, cut: body.cut !== false, openDrawer: body.openDrawer === true }), { copies: body.copies });
    return sendJson(response, 200, { ok: true, job: result });
  }

  if (request.method === 'POST' && pathname === '/api/print/raw') {
    const body = await readJson(request);
    if (typeof body.dataBase64 !== 'string' || body.dataBase64.length === 0 || body.dataBase64.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(body.dataBase64)) {
      throw Object.assign(new Error('dataBase64 must contain valid base64-encoded ESC/POS bytes.'), { statusCode: 400 });
    }
    const result = await manager.enqueue(Buffer.from(body.dataBase64, 'base64'), { copies: body.copies });
    return sendJson(response, 200, { ok: true, job: result });
  }

  return sendJson(response, 404, { ok: false, error: 'Not found.' });
}

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
    if (url.pathname.startsWith('/api/')) return await handleApi(request, response, url.pathname);
    if (request.method === 'GET' && staticFiles[url.pathname]) return sendStatic(response, url.pathname);
    return sendJson(response, 404, { ok: false, error: 'Not found.' });
  } catch (error) {
    logger.warn('Request failed', { method: request.method, url: request.url, error: error.message });
    return sendJson(response, error.statusCode || 500, { ok: false, error: error.message });
  }
});

server.requestTimeout = 45_000;
server.headersTimeout = 10_000;
server.keepAliveTimeout = 5_000;

async function start() {
  await manager.start();
  server.listen(config.port, config.host, () => {
    logger.info('Local receipt printer started', {
      url: `http://${config.host}:${config.port}`,
      version: packageJson.version,
      platform: process.platform,
      node: process.version,
      queueDepth: manager.queueDepth,
    });
  });
}

async function shutDown(signal) {
  logger.info('Shutting down', { signal });
  await manager.stop();
  server.close((error) => {
    if (error) logger.error('Shutdown failed', { error: error.message });
    process.exit(error ? 1 : 0);
  });
  setTimeout(() => process.exit(1), 10_000).unref();
}

process.on('SIGINT', () => shutDown('SIGINT'));
process.on('SIGTERM', () => shutDown('SIGTERM'));
process.on('uncaughtException', (error) => {
  logger.error('Uncaught exception', { error: error.stack || error.message });
  process.exit(1);
});
process.on('unhandledRejection', (error) => {
  logger.error('Unhandled rejection', { error: error && (error.stack || error.message) || String(error) });
  process.exit(1);
});

start().catch((error) => {
  logger.error('Startup failed', { error: error.stack || error.message });
  process.exit(1);
});
