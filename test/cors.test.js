'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { applyCorsHeaders, handlePreflight, originIsAllowed, requestedHeadersAreAllowed } = require('../src/cors');

test('allows the exact Glass Pane production origin and loopback origins', () => {
  assert.equal(originIsAllowed('https://glass-pane.aistone.com'), true);
  assert.equal(originIsAllowed('http://127.0.0.1:3000'), true);
  assert.equal(originIsAllowed('http://localhost:17890'), true);
  assert.equal(originIsAllowed(undefined), true);
});

test('rejects lookalike, insecure, and unrelated origins', () => {
  assert.equal(originIsAllowed('https://glass-pane.aistone.com.example.com'), false);
  assert.equal(originIsAllowed('http://glass-pane.aistone.com'), false);
  assert.equal(originIsAllowed('https://example.com'), false);
  assert.equal(originIsAllowed('not an origin'), false);
});

test('preflight permits only the Content-Type request header', () => {
  assert.equal(requestedHeadersAreAllowed('content-type'), true);
  assert.equal(requestedHeadersAreAllowed('Content-Type'), true);
  assert.equal(requestedHeadersAreAllowed('Authorization'), false);
});

test('adds a reflected origin without enabling credentials', () => {
  const headers = {};
  const response = { setHeader: (name, value) => { headers[name] = value; } };
  applyCorsHeaders({ headers: { origin: 'https://glass-pane.aistone.com' } }, response);
  assert.deepEqual(headers, {
    'Access-Control-Allow-Origin': 'https://glass-pane.aistone.com',
    Vary: 'Origin',
  });
});

test('answers an allowed private-network preflight', () => {
  const result = { status: null, headers: null, ended: false };
  const response = {
    writeHead(status, headers) { result.status = status; result.headers = headers; },
    end() { result.ended = true; },
  };
  const handled = handlePreflight({ headers: {
    'access-control-request-method': 'POST',
    'access-control-request-headers': 'content-type',
    'access-control-request-private-network': 'true',
  } }, response);
  assert.equal(handled, true);
  assert.equal(result.status, 204);
  assert.equal(result.headers['Access-Control-Allow-Origin'], undefined);
  assert.equal(result.headers['Access-Control-Allow-Private-Network'], 'true');
  assert.equal(result.ended, true);
});

test('rejects unsupported preflight methods and headers', () => {
  const response = { writeHead() { throw new Error('should not respond'); }, end() {} };
  assert.equal(handlePreflight({ headers: { 'access-control-request-method': 'DELETE' } }, response), false);
  assert.equal(handlePreflight({ headers: {
    'access-control-request-method': 'POST',
    'access-control-request-headers': 'authorization',
  } }, response), false);
});
