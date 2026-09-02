'use strict';

const ESC = 0x1b;
const GS = 0x1d;
const FS = 0x1c;

function normalizeText(text) {
  return String(text).replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

function textReceipt({ text, cut = true, openDrawer = false }) {
  const chunks = [
    Buffer.from([ESC, 0x40]), // Initialize printer.
    Buffer.from([FS, 0x28, 0x43, 0x02, 0x00, 0x30, 0x02]), // Select UTF-8 on the TM-m30III.
    Buffer.from(normalizeText(text), 'utf8'),
  ];

  if (!String(text).endsWith('\n')) chunks.push(Buffer.from('\n'));
  chunks.push(Buffer.from('\n\n\n'));
  if (openDrawer) chunks.push(Buffer.from([ESC, 0x70, 0x00, 0x19, 0xfa]));
  if (cut) chunks.push(Buffer.from([GS, 0x56, 0x42, 0x00]));
  return Buffer.concat(chunks);
}

module.exports = { normalizeText, textReceipt };
