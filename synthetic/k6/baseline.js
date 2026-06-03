// k6 baseline scenario — Section 13.2.
//
// Goal: model a quiet business-hours traffic floor against the corp-a1 REST
// API stub. Run by Container Apps Job `caj-k6-baseline-...` on weekdays at
// 09:00 local-to-cluster (UTC in cron). The 9h ramp covers a working day
// before the job replica times out.
//
// Targets (relative to TARGET_BASE_URL):
//   GET  /api/products
//   POST /api/login   (valid creds — drives healthy 200s)
//   POST /api/checkout
//
// The console summary is captured by Container Apps and shipped to the
// Platform LAW workspace via the environment's logs_destination=log-analytics
// integration. Section 6 analytics rules can then read from the
// ContainerAppConsoleLogs_CL table.

import http from 'k6/http';
import { sleep, check } from 'k6';

const BASE_URL = (__ENV.TARGET_BASE_URL || 'http://localhost:8080').replace(/\/$/, '');

export const options = {
  scenarios: {
    business_hours: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15m', target: 2 },   // morning ramp
        { duration: '8h', target: 5 },    // sustained business day
        { duration: '15m', target: 0 },   // evening wind-down
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<1500'],
  },
  tags: {
    scenario: 'baseline',
    workload: 'corp-a1',
  },
};

export default function () {
  const products = http.get(`${BASE_URL}/api/products`, { tags: { endpoint: 'products' } });
  check(products, { 'products 200': (r) => r.status === 200 });
  sleep(2);

  const login = http.post(
    `${BASE_URL}/api/login`,
    JSON.stringify({ username: 'demo', password: 'demo123' }),
    { headers: { 'content-type': 'application/json' }, tags: { endpoint: 'login' } },
  );
  check(login, { 'login 200': (r) => r.status === 200 });
  sleep(3);

  const checkout = http.post(
    `${BASE_URL}/api/checkout`,
    JSON.stringify({ items: [{ id: 'sku-001', priceUsd: 1499, qty: 1 }] }),
    { headers: { 'content-type': 'application/json' }, tags: { endpoint: 'checkout' } },
  );
  check(checkout, { 'checkout 200': (r) => r.status === 200 });
  sleep(5);
}
