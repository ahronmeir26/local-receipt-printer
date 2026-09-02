'use strict';

const LOOPBACK_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '[::1]']);
const TRUSTED_WEB_ORIGINS = new Set(['https://glass-pane.aistone.com']);
const ALLOWED_PREFLIGHT_METHODS = new Set(['GET', 'POST']);
const ALLOWED_PREFLIGHT_HEADERS = new Set(['content-type']);

function originIsAllowed(origin) {
  if (!origin) return true;
  try {
    const url = new URL(origin);
    return TRUSTED_WEB_ORIGINS.has(url.origin) || LOOPBACK_HOSTNAMES.has(url.hostname);
  } catch {
    return false;
  }
}

function requestedHeadersAreAllowed(value) {
  if (!value) return true;
  return String(value)
    .split(',')
    .map((header) => header.trim().toLowerCase())
    .filter(Boolean)
    .every((header) => ALLOWED_PREFLIGHT_HEADERS.has(header));
}

function applyCorsHeaders(request, response) {
  const origin = request.headers.origin;
  if (!origin || !originIsAllowed(origin)) return;
  response.setHeader('Access-Control-Allow-Origin', origin);
  response.setHeader('Vary', 'Origin');
}

function handlePreflight(request, response) {
  const requestedMethod = String(request.headers['access-control-request-method'] || '').toUpperCase();
  const requestedHeaders = request.headers['access-control-request-headers'];

  if (!ALLOWED_PREFLIGHT_METHODS.has(requestedMethod) || !requestedHeadersAreAllowed(requestedHeaders)) {
    return false;
  }

  response.writeHead(204, {
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Max-Age': '600',
    ...(String(request.headers['access-control-request-private-network'] || '').toLowerCase() === 'true'
      ? { 'Access-Control-Allow-Private-Network': 'true' }
      : {}),
  });
  response.end();
  return true;
}

module.exports = { applyCorsHeaders, handlePreflight, originIsAllowed, requestedHeadersAreAllowed };
