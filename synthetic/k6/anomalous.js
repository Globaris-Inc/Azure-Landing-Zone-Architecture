// k6 anomalous scenario — Section 13.2.
//
// Goal: a sharp, short, suspicious-looking burst — 200 VUs over 5 minutes —
// that also seeds the Section 6 "blocked-country sign-in" + brute-force
// analytics rules with deliberately mislabelled traffic. The traffic is still
// sourced from the eastus2 Container Apps environment; the geo "non-approved"
// classification is conveyed by request headers so the KQL detection logic in
// Section 6 can tag it without needing a second-region environment.
//
// Real cross-region simulation (impossible-travel etc.) is the §13.3
// red-team simulator ACI's job.

import http from 'k6/http';
import { sleep, check } from 'k6';

const BASE_URL = (__ENV.TARGET_BASE_URL || 'http://localhost:8080').replace(/\/$/, '');

const ANOMALY_HEADERS = {
  'content-type': 'application/json',
  'x-test-geo': 'simulated-nonapproved-eu',
  'x-test-scenario': 'k6-anomalous',
};

export const options = {
  scenarios: {
    anomalous_burst: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 200 },
        { duration: '4m', target: 200 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    // Anomalous is allowed to fail — we are intentionally stressing the API
    // and seeding 401 signals. Looser thresholds prevent spurious job failure.
    http_req_failed: ['rate<0.60'],
  },
  tags: {
    scenario: 'anomalous',
    workload: 'corp-a1',
    geo: 'simulated-nonapproved',
  },
};

export default function () {
  // 60% of the traffic is failed-login bursts — drives the brute-force +
  // legacy-auth Sentinel rules.
  if (Math.random() < 0.6) {
    const badLogin = http.post(
      `${BASE_URL}/api/login`,
      JSON.stringify({ username: `attacker-${__VU}`, password: 'wrong-password' }),
      { headers: ANOMALY_HEADERS, tags: { endpoint: 'login', expected: '401' } },
    );
    check(badLogin, { 'login 401': (r) => r.status === 401 });
  } else {
    const products = http.get(`${BASE_URL}/api/products`, {
      headers: ANOMALY_HEADERS,
      tags: { endpoint: 'products', expected: '200' },
    });
    check(products, { 'products 200': (r) => r.status === 200 });
  }

  // No sleep — sustained pressure.
}
