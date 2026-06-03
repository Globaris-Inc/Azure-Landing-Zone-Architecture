// Synthetic REST API stub for the corp-a1 landing-zone App Service.
// Section 13.1 — Workload Targets (PROMPT.md).
//
// Zero npm dependencies on purpose: WEBSITE_RUN_FROM_PACKAGE=1 mounts the zip
// read-only, so a runtime `npm install` is impossible. Anything more elaborate
// than this stub belongs in a real CI build step that vendors node_modules
// into the zip before upload.
//
// Endpoints:
//   GET  /                — liveness probe (also used by App Gateway health probe)
//   GET  /api/products    — returns a small static catalog
//   POST /api/login       — toy auth: 200 for ("demo","demo123"), 401 otherwise
//                            (the deliberate 401-on-bad-creds path drives the
//                            failed-sign-in synthetic signal in Section 13.3)
//   POST /api/checkout    — accepts a cart payload, returns a mock order id
//   GET  /api/healthz     — JSON liveness/version response

'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = process.env.PORT || 8080;
const VERSION = '0.1.0';

const PRODUCTS = [
  { id: 'sku-001', name: 'Hub Router Pro', priceUsd: 1499.0, stock: 12 },
  { id: 'sku-002', name: 'Edge Switch 48p', priceUsd: 879.0, stock: 35 },
  { id: 'sku-003', name: 'Wifi 7 Mesh Kit', priceUsd: 449.0, stock: 80 },
  { id: 'sku-004', name: 'Transceiver SR4', priceUsd: 119.0, stock: 250 },
  { id: 'sku-005', name: 'Patch Cable 10m', priceUsd: 9.5, stock: 1200 }
];

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store'
  });
  res.end(payload);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/' && req.method === 'GET') {
    return send(res, 200, { service: 'corp-a1-api', version: VERSION, ok: true });
  }

  if (url.pathname === '/api/healthz' && req.method === 'GET') {
    return send(res, 200, { ok: true, version: VERSION, uptimeSeconds: process.uptime() });
  }

  if (url.pathname === '/api/products' && req.method === 'GET') {
    return send(res, 200, { count: PRODUCTS.length, items: PRODUCTS });
  }

  if (url.pathname === '/api/login' && req.method === 'POST') {
    let body;
    try {
      body = await readBody(req);
    } catch {
      return send(res, 400, { error: 'invalid_json' });
    }
    const { username, password } = body;
    if (username === 'demo' && password === 'demo123') {
      return send(res, 200, { ok: true, token: crypto.randomBytes(24).toString('hex') });
    }
    return send(res, 401, { ok: false, error: 'invalid_credentials' });
  }

  if (url.pathname === '/api/checkout' && req.method === 'POST') {
    let body;
    try {
      body = await readBody(req);
    } catch {
      return send(res, 400, { error: 'invalid_json' });
    }
    const items = Array.isArray(body.items) ? body.items : [];
    const total = items.reduce((sum, item) => sum + Number(item.priceUsd || 0) * Number(item.qty || 1), 0);
    return send(res, 200, {
      ok: true,
      orderId: crypto.randomUUID(),
      totalUsd: Number(total.toFixed(2)),
      itemCount: items.length
    });
  }

  return send(res, 404, { error: 'not_found', path: url.pathname });
});

server.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`corp-a1-api listening on :${PORT}`);
});
