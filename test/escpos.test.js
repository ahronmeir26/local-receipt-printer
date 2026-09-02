'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { textReceipt } = require('../src/escpos');

test('textReceipt initializes, normalizes lines, feeds, and cuts', () => {
  const result = textReceipt({ text: 'one\r\ntwo', cut: true });
  assert.deepEqual([...result.subarray(0, 2)], [0x1b, 0x40]);
  assert.equal(result.includes(Buffer.from([0x1c, 0x28, 0x43, 0x02, 0x00, 0x30, 0x02])), true);
  assert.match(result.toString('utf8'), /one\ntwo\n\n\n\n/);
  assert.deepEqual([...result.subarray(-4)], [0x1d, 0x56, 0x42, 0x00]);
});

test('textReceipt omits cut and can open the drawer', () => {
  const result = textReceipt({ text: 'test\n', cut: false, openDrawer: true });
  assert.equal(result.includes(Buffer.from([0x1d, 0x56])), false);
  assert.equal(result.includes(Buffer.from([0x1b, 0x70, 0x00, 0x19, 0xfa])), true);
});
