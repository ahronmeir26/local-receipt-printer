'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { PrinterManager, selectPrinter } = require('../src/printer-manager');

const printer = (name, values = {}) => ({ name, isDefault: false, isOffline: false, deviceUri: null, driverName: null, ...values });

test('configured exact printer wins', () => {
  const printers = [printer('Office'), printer('EPSON_TM_m30III')];
  assert.equal(selectPrinter(printers, { printerName: 'Office', printerMatch: 'TM-m30' }).printer.name, 'Office');
});

test('TM-m30 is discovered despite punctuation differences', () => {
  const printers = [printer('Office'), printer('EPSON_TM_m30III')];
  const selected = selectPrinter(printers, { printerName: null, printerMatch: 'TM-m30' });
  assert.equal(selected.printer.name, 'EPSON_TM_m30III');
});

test('a uniquely online matching printer wins', () => {
  const printers = [printer('TM-m30III A', { isOffline: true }), printer('TM-m30III B')];
  assert.equal(selectPrinter(printers, { printerName: null, printerMatch: 'TM-m30' }).printer.name, 'TM-m30III B');
});

test('an offline configured queue can be replaced by a unique online model queue', () => {
  const printers = [printer('TM-m30III old', { isOffline: true }), printer('TM-m30III USB')];
  const selected = selectPrinter(printers, { printerName: 'TM-m30III old', printerMatch: 'TM-m30' });
  assert.equal(selected.printer.name, 'TM-m30III USB');
  assert.match(selected.reason, /rediscovered/);
});

test('ambiguous matches require a selection', () => {
  const printers = [printer('TM-m30III A'), printer('TM-m30III B')];
  const selected = selectPrinter(printers, { printerName: null, printerMatch: 'TM-m30' });
  assert.equal(selected.printer, null);
  assert.match(selected.reason, /Multiple matching printers/);
});

test('an unrelated single printer is never selected automatically', () => {
  const selected = selectPrinter([printer('Office LaserJet')], { printerName: null, printerMatch: 'TM-m30' });
  assert.equal(selected.printer, null);
  assert.match(selected.reason, /no unique TM-m30 printer/i);
});

test('a print job retries in memory, reaches the spooler, and removes its temporary file', async () => {
  const jobsDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'receipt-printer-test-'));
  let attempts = 0;
  const platform = {
    listPrinters: async () => [printer('EPSON_TM_m30III')],
    printFile: async (printerName, filePath) => {
      attempts += 1;
      assert.equal(printerName, 'EPSON_TM_m30III');
      if (attempts === 1) throw new Error('temporary spooler error');
      assert.deepEqual(await fs.readFile(filePath), Buffer.from('receipt bytes'));
      return 'mock spooler job 1';
    },
  };
  const manager = new PrinterManager(
    { printerName: null, printerMatch: 'TM-m30' },
    { platform, jobsDirectory, retryDelaysMs: [5], discoveryIntervalMs: 60_000 },
  );

  try {
    const result = await manager.enqueue(Buffer.from('receipt bytes'));
    assert.equal(result.status, 'accepted-by-spooler');
    assert.equal(attempts, 2);
    assert.deepEqual(await fs.readdir(jobsDirectory), []);
  } finally {
    await manager.stop();
    await fs.rm(jobsDirectory, { recursive: true, force: true });
  }
});

test('stale unaccepted job files are discarded on manager restart', async () => {
  const jobsDirectory = await fs.mkdtemp(path.join(os.tmpdir(), 'receipt-printer-recovery-test-'));
  const platform = {
    listPrinters: async () => [],
    printFile: async () => { throw new Error('should not print'); },
  };
  const manager = new PrinterManager(
    { printerName: null, printerMatch: 'TM-m30' },
    { platform, jobsDirectory, discoveryIntervalMs: 60_000 },
  );

  try {
    await fs.writeFile(path.join(jobsDirectory, 'old.bin'), 'unaccepted');
    await fs.writeFile(path.join(jobsDirectory, 'old.tmp'), 'partial');
    await fs.writeFile(path.join(jobsDirectory, 'keep.txt'), 'not a job');
    await manager.start();
    assert.deepEqual(await fs.readdir(jobsDirectory), ['keep.txt']);
  } finally {
    await manager.stop();
    await fs.rm(jobsDirectory, { recursive: true, force: true });
  }
});
