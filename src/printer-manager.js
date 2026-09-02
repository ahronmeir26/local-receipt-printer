'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');
const { ensureDataDirectory, saveConfig } = require('./config');
const platform = require('./platform-printers');
const logger = require('./logger');

const DEFAULT_RETRY_DELAYS_MS = [500, 1_500, 5_000, 15_000];
const DEFAULT_DISCOVERY_INTERVAL_MS = 10_000;

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function searchable(printer) {
  return [printer.name, printer.deviceUri, printer.driverName].filter(Boolean).join(' ').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function selectPrinter(printers, config) {
  if (!printers.length) return { printer: null, reason: 'No printers are installed.' };

  let configuredOffline = null;
  if (config.printerName) {
    const exact = printers.find((printer) => printer.name === config.printerName);
    if (exact && !exact.isOffline) return { printer: exact, reason: 'Configured printer' };
    configuredOffline = exact || null;

    const normalizedName = config.printerName.toLowerCase().replace(/[^a-z0-9]/g, '');
    const renamed = printers.filter((printer) => {
      const candidate = printer.name.toLowerCase().replace(/[^a-z0-9]/g, '');
      return !printer.isOffline && (candidate.includes(normalizedName) || normalizedName.includes(candidate));
    });
    if (renamed.length === 1) return { printer: renamed[0], reason: 'Configured printer was rediscovered under a similar name' };
  }

  const wanted = String(config.printerMatch || 'TM-m30').toLowerCase().replace(/[^a-z0-9]/g, '');
  const matching = printers.filter((printer) => searchable(printer).includes(wanted));
  if (matching.length === 1) return { printer: matching[0], reason: `Only printer matching “${config.printerMatch}”` };
  if (matching.length > 1) {
    const online = matching.filter((printer) => !printer.isOffline);
    if (online.length === 1) return { printer: online[0], reason: configuredOffline ? 'Configured printer was rediscovered on an online queue' : 'Only online matching printer' };
    const preferredDefault = matching.find((printer) => printer.isDefault);
    if (preferredDefault) return { printer: preferredDefault, reason: 'Default matching printer' };
    return { printer: null, reason: 'Multiple matching printers found. Choose one in Settings.' };
  }

  if (configuredOffline) return { printer: configuredOffline, reason: 'Configured printer is offline' };
  return { printer: null, reason: 'Printer not configured and no unique TM-m30 printer was found.' };
}

class PrinterManager {
  constructor(config, dependencies = {}) {
    this.config = config;
    this.platform = dependencies.platform || platform;
    this.jobsDirectory = dependencies.jobsDirectory || path.join(ensureDataDirectory(), 'jobs');
    this.retryDelaysMs = dependencies.retryDelaysMs || DEFAULT_RETRY_DELAYS_MS;
    this.discoveryIntervalMs = dependencies.discoveryIntervalMs || DEFAULT_DISCOVERY_INTERVAL_MS;
    this.queue = Promise.resolve();
    this.queueDepth = 0;
    this.started = false;
    this.startPromise = null;
    this.discoveryTimer = null;
    this.lastDiscovery = null;
    this.lastJob = null;
  }

  async start() {
    if (this.started) return;
    if (this.startPromise) return this.startPromise;
    this.startPromise = this.initialize();
    try {
      await this.startPromise;
      this.started = true;
    } finally {
      this.startPromise = null;
    }
  }

  async initialize() {
    await fs.mkdir(this.jobsDirectory, { recursive: true });
    const staleFiles = (await fs.readdir(this.jobsDirectory)).filter((name) => name.endsWith('.bin') || name.endsWith('.tmp'));
    await Promise.all(staleFiles.map((name) => fs.unlink(path.join(this.jobsDirectory, name)).catch(() => {})));
    if (staleFiles.length) logger.info('Discarded stale unaccepted print jobs after restart', { count: staleFiles.length });
    try {
      await this.discover();
    } catch (error) {
      logger.warn('Initial printer discovery failed; background discovery will retry', { error: error.message });
    }
    this.discoveryTimer = setInterval(() => {
      this.discover().catch((error) => logger.warn('Background printer discovery failed', { error: error.message }));
    }, this.discoveryIntervalMs);
    this.discoveryTimer.unref?.();
  }

  async stop() {
    if (this.discoveryTimer) clearInterval(this.discoveryTimer);
    this.discoveryTimer = null;
    this.started = false;
  }

  async discover() {
    const printers = await this.platform.listPrinters();
    const selection = selectPrinter(printers, this.config);
    if (this.config.printerName && selection.printer && selection.printer.name !== this.config.printerName && /rediscovered/.test(selection.reason)) {
      const previousName = this.config.printerName;
      this.config.printerName = selection.printer.name;
      saveConfig(this.config);
      logger.info('Persisted rediscovered printer name', { previousName, printerName: this.config.printerName });
    }
    this.lastDiscovery = {
      at: new Date().toISOString(),
      printers,
      selectedPrinter: selection.printer,
      selectionReason: selection.reason,
    };
    return this.lastDiscovery;
  }

  setPrinter(printerName) {
    this.config.printerName = printerName || null;
    saveConfig(this.config);
    logger.info('Printer configuration updated', { printerName: this.config.printerName });
  }

  async enqueue(buffer, options = {}) {
    if (!Buffer.isBuffer(buffer) || buffer.length === 0) throw Object.assign(new Error('Print data is empty.'), { statusCode: 400 });
    if (buffer.length > 2 * 1024 * 1024) throw Object.assign(new Error('Print data exceeds the 2 MB limit.'), { statusCode: 400 });
    const copies = Number(options.copies || 1);
    if (!Number.isInteger(copies) || copies < 1 || copies > 10) throw Object.assign(new Error('Copies must be between 1 and 10.'), { statusCode: 400 });
    await this.start();

    const jobId = crypto.randomUUID();
    this.queueDepth += 1;
    const work = this.queue.then(() => this.runJob(jobId, buffer, copies));
    this.queue = work.catch(() => {}).finally(() => { this.queueDepth -= 1; });
    return work;
  }

  async runJob(jobId, buffer, copies) {
    await fs.mkdir(this.jobsDirectory, { recursive: true });
    const filePath = path.join(this.jobsDirectory, `${jobId}.bin`);
    await fs.writeFile(filePath, buffer, { mode: 0o600 });
    const startedAt = new Date().toISOString();
    logger.info('Print job started', { jobId, bytes: buffer.length, copies });

    try {
      const outputs = [];
      for (let copy = 1; copy <= copies; copy += 1) {
        let accepted = false;
        let lastError;
        const maximumAttempts = this.retryDelaysMs.length + 1;
        for (let attempt = 1; attempt <= maximumAttempts && !accepted; attempt += 1) {
          try {
            const discovery = await this.discover();
            if (!discovery.selectedPrinter) throw new Error(discovery.selectionReason);
            if (discovery.selectedPrinter.isOffline) throw new Error(`Printer “${discovery.selectedPrinter.name}” is offline.`);
            const spoolerResponse = await this.platform.printFile(discovery.selectedPrinter.name, filePath);
            outputs.push({ copy, printer: discovery.selectedPrinter.name, spoolerResponse });
            accepted = true;
          } catch (error) {
            lastError = error;
            logger.warn('Print attempt failed', { jobId, copy, attempt, maximumAttempts, error: error.message });
            if (attempt < maximumAttempts) await sleep(this.retryDelaysMs[attempt - 1]);
          }
        }
        if (!accepted) throw lastError;
      }

      this.lastJob = { jobId, status: 'accepted-by-spooler', startedAt, finishedAt: new Date().toISOString(), outputs };
      logger.info('Print job accepted by spooler', this.lastJob);
      return this.lastJob;
    } catch (error) {
      this.lastJob = { jobId, status: 'failed', startedAt, finishedAt: new Date().toISOString(), error: error.message };
      logger.error('Print job failed', this.lastJob);
      if (!error.statusCode) error.statusCode = 503;
      throw error;
    } finally {
      try { await fs.unlink(filePath); } catch (error) { if (error.code !== 'ENOENT') logger.warn('Could not remove job file', { filePath, error: error.message }); }
    }
  }
}

module.exports = { PrinterManager, selectPrinter };
