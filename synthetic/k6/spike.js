// k6 spike scenario — Section 13.2.
//
// Goal: simulate a marketing-email / flash-sale burst against the corp-a1 REST
// API. 50 VUs for ~15 minutes, twice a week. Drives App Service auto-scale
// telemetry and lights up the Sentinel rules that watch for sustained traffic
// anomalies.

import http from 'k6/http';
import { sleep, check } from 'k6';

const BASE_URL = (__ENV.TARGET_BASE_URL || 'http://localhost:8080').replace(/\/$/, '');

export const options = {
  scenarios: {
    business_spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 50 },   // rapid ramp-up
        { duration: '10m', target: 50 },  // hold
        { duration: '3m', target: 0 },    // ramp down
      ],
      gracefulRampDown: '15s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.10'],
    http_req_duration: ['p(95)<2500'],
  },
  tags: {
    scenario: 'spike',
    workload: 'corp-a1',
  },
};

export default function () {
  // Browse-heavy mix — more product views per checkout.
  const products = http.get(`${BASE_URL}/api/products`, { tags: { endpoint: 'products' } });
  check(products, { 'products 200': (r) => r.status === 200 });
  sleep(1);

  if (Math.random() < 0.4) {
    const login = http.post(
      `${BASE_URL}/api/login`,
      JSON.stringify({ username: 'demo', password: 'demo123' }),
      { headers: { 'content-type': 'application/json' }, tags: { endpoint: 'login' } },
    );
    check(login, { 'login 200': (r) => r.status === 200 });
    sleep(0.5);
  }

  if (Math.random() < 0.2) {
    const checkout = http.post(
      `${BASE_URL}/api/checkout`,
      JSON.stringify({
        items: [
          { id: 'sku-001', priceUsd: 1499, qty: 1 },
          { id: 'sku-005', priceUsd: 9.5, qty: 4 },
        ],
      }),
      { headers: { 'content-type': 'application/json' }, tags: { endpoint: 'checkout' } },
    );
    check(checkout, { 'checkout 200': (r) => r.status === 200 });
  }

  sleep(1);
}
