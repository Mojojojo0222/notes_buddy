// Run: k6 run --env BASE=$BASE --env SCENARIO=mixed load-test.js
// Scenarios: ingest | search | mixed | pollers
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE || 'http://localhost:9098';
const SCENARIO = __ENV.SCENARIO || 'mixed';

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '2m', target: 50 },
        { duration: '5m', target: 50 },
        { duration: '2m', target: 0 },
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<2000'],
  },
};

const queries = ['docker', 'git', 'terraform', 'kubectl', 'notes-buddy', '%', '___', 'a b'];
const commands = [
  'kubectl get pods -n kube-system',
  'docker build -t notes-buddy .',
  'git commit -m "fix: csi addon"',
  'terraform plan -out=plan.tfplan',
  'aws eks update-kubeconfig --name notes-buddy',
  'helm upgrade notes-buddy ./helm/notes-buddy',
];

export default function () {
  if (SCENARIO === 'ingest') {
    const text = commands[Math.floor(Math.random() * commands.length)];
    const res = http.post(`${BASE}/ingest`, {
      text, workingDir: '/repos/test', repoName: 'notes-buddy', exitCode: '0',
    });
    check(res, { 'ingest 200': r => r.status === 200 });
    sleep(0.1);
  } else if (SCENARIO === 'search') {
    const q = queries[Math.floor(Math.random() * queries.length)];
    const res = http.get(`${BASE}/commands/search?q=${encodeURIComponent(q)}`);
    check(res, { 'search 200': r => r.status === 200 });
    sleep(0.2);
  } else if (SCENARIO === 'pollers') {
    const res = http.get(`${BASE}/sessions`);
    check(res, { 'sessions 200': r => r.status === 200 });
    sleep(15);
  } else {
    const r = Math.random();
    let res;
    if (r < 0.7)      res = http.get(`${BASE}/sessions`);
    else if (r < 0.9) res = http.post(`${BASE}/ingest`, { text: commands[0], workingDir: '/tmp', repoName: 'x', exitCode: '0' });
    else              res = http.get(`${BASE}/commands/search?q=docker`);
    check(res, { '200': r => r.status === 200 });
    sleep(0.5);
  }
}
