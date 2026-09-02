'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { WindowsKioskController } = require('../src/windows-kiosk');

test('signs out the active console session exactly once and returns auditable metadata', async () => {
  let calls = 0;
  const controller = new WindowsKioskController({
    platform: 'win32',
    now: () => Date.parse('2026-09-02T20:00:00.000Z'),
    signOutSession: async () => { calls += 1; return 1; },
  });

  const result = await controller.exitKiosk();

  assert.equal(calls, 1);
  assert.deepEqual(result, {
    action: 'exit-kiosk',
    status: 'completed',
    sessionId: 1,
    requestedAt: '2026-09-02T20:00:00.000Z',
  });
});

test('rejects unsupported platforms without starting a service', async () => {
  let calls = 0;
  const controller = new WindowsKioskController({
    platform: 'darwin',
    signOutSession: async () => { calls += 1; return 1; },
  });

  await assert.rejects(controller.exitKiosk(), (error) => {
    assert.equal(error.statusCode, 501);
    return true;
  });
  assert.equal(calls, 0);
});

test('rejects concurrent and rapid repeated requests', async () => {
  let release;
  let currentTime = 10_000;
  const controller = new WindowsKioskController({
    platform: 'win32',
    now: () => currentTime,
    signOutSession: () => new Promise((resolve) => { release = () => resolve(1); }),
  });

  const first = controller.exitKiosk();
  await assert.rejects(controller.exitKiosk(), (error) => {
    assert.equal(error.statusCode, 409);
    return true;
  });
  release();
  await first;

  currentTime += 1_000;
  await assert.rejects(controller.exitKiosk(), (error) => {
    assert.equal(error.statusCode, 429);
    return true;
  });
});

test('surfaces a Windows console sign-out failure', async () => {
  const controller = new WindowsKioskController({
    platform: 'win32',
    signOutSession: async () => { throw new Error('no active console session'); },
  });

  await assert.rejects(controller.exitKiosk(), (error) => {
    assert.equal(error.statusCode, 500);
    assert.match(error.message, /no active console/);
    return true;
  });
});
