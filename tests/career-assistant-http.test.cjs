'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { once } = require('node:events');
const { createCareerService } = require('../scripts/career-server.cjs');
test('v2 endpoints require authentication, allow only paired extension origin and preserve v1', async t => {
  const parent = path.resolve('.test-tmp'); fs.mkdirSync(parent, { recursive: true });
  const dataDir = fs.mkdtempSync(path.join(parent, 'assistant-http-'));
  const token = 'local-test-token-with-enough-randomness';
  let loginCalls = 0;
  const s = createCareerService({ dataDir, token, env: {}, xhsDir: path.join(dataDir, 'xhs'), refreshCooldown: 0,
    openLogin: async () => { loginCalls++; return { state: 'awaiting_user' }; },
    collect: async () => ({ state: 'not_configured', jobs: [], message: 'test' }) });
  s.server.listen(0, '127.0.0.1'); await once(s.server, 'listening');
  t.after(async () => { await s.assistant.close(); s.server.closeAllConnections(); await new Promise(r => s.server.close(r)); fs.rmSync(dataDir, { recursive: true, force: true }); });
  const endpoint = `http://127.0.0.1:${s.server.address().port}`;
  const get = (route, headers = {}) => fetch(endpoint + route, { headers });
  assert.equal((await get('/v2/career/snapshot')).status, 401);
  assert.equal((await get('/v2/career/snapshot', { Authorization: 'Bearer ' + token, Origin: 'https://evil.test' })).status, 403);
  const response = await get('/v2/career/snapshot', { Authorization: 'Bearer ' + token, Origin: 'chrome-extension://hlmdaklafhleodnklhdbkbjmkbkfmgpc' });
  assert.equal(response.status, 200); const snapshot = await response.json(); assert.equal(snapshot.schemaVersion, 2); assert.equal(snapshot.profiles.length, 1); assert.ok(snapshot.sources.length);
  assert.ok(!JSON.stringify(snapshot).includes(token));
  assert.equal((await get('/v1/career/feed', { Authorization: 'Bearer ' + token })).status, 200);
  const html = await get('/career');
  assert.equal(html.status, 200); assert.match(html.headers.get('content-security-policy'), /frame-ancestors 'none'/); assert.ok(!(await html.text()).includes(token));
  assert.equal((await get('/career/workbench.js')).status,200);
  assert.equal((await get('/career/../../data/career-private/token.txt')).status,401);
  const sameOrigin = await fetch(endpoint+'/v2/career/sync',{method:'POST',headers:{Origin:endpoint,Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({operations:[]})});
  assert.equal(sameOrigin.status,200);
  const imported = await fetch(endpoint + '/v2/career/browser/import', { method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: JSON.stringify({ sourceID: 'boss', jobs: [{ company: '测试公司', title: '机器人实习', city: '杭州', url: 'http://127.0.0.1/secret' }] }) });
  assert.equal(imported.status, 400); assert.equal(s.assistant.snapshot().jobs.length, 0);
  const login = (extraHeaders = {}, body = { sourceID: 'boss' }) => fetch(endpoint + '/v2/career/browser/login',
    { method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', ...extraHeaders }, body: JSON.stringify(body) });
  assert.equal((await login({ Authorization: '' })).status, 401);
  assert.equal((await login({ 'X-Forwarded-For': '100.100.0.1' })).status, 403);
  assert.equal((await login({ Origin: 'chrome-extension://hlmdaklafhleodnklhdbkbjmkbkfmgpc' })).status, 403);
  assert.equal((await login({}, { sourceID: 'arbitrary-program' })).status, 400);
  assert.equal(loginCalls, 0);
  const previous = s.assistant.snapshot().sources.find(v => v.id === 'boss');
  assert.equal((await login({ Origin: endpoint })).status, 200);
  assert.equal((await login()).status, 429);
  assert.equal(loginCalls, 1);
  assert.deepEqual(s.assistant.snapshot().sources.find(v => v.id === 'boss'), previous);
  const diagnostic = { version: 1, sourceID: 'boss', pageKind: 'search', readyState: 'complete',
    jobLinks: 2, frames: 0, cards: 0, titleFields: 2, companyFields: 0,
    samples: [{ parents: [{ tag: 'li', classes: ['job-card-wrap'], textLength: 50 }], children: [] }],
    rawHTML: 'sensitive-text-must-be-dropped', cookies: 'secret-must-be-dropped' };
  const saveDiagnostic = (headers = {}, body = diagnostic) => fetch(endpoint + '/v2/career/browser/diagnostics', {
    method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', Origin: 'chrome-extension://hlmdaklafhleodnklhdbkbjmkbkfmgpc', ...headers },
    body: JSON.stringify(body) });
  assert.equal((await saveDiagnostic({ Authorization: '' })).status, 401);
  assert.equal((await saveDiagnostic({ 'X-Forwarded-For': '100.100.0.1' })).status, 403);
  assert.equal((await saveDiagnostic({}, { ...diagnostic, samples: Array(3).fill(diagnostic.samples[0]) })).status, 400);
  assert.equal((await saveDiagnostic()).status, 200);
  const savedDiagnostic = fs.readFileSync(path.join(dataDir, 'browser-diagnostics-boss.json'), 'utf8');
  assert.ok(!savedDiagnostic.includes('must-be-dropped'));
  assert.equal(JSON.parse(savedDiagnostic).jobLinks, 2);
  assert.deepEqual(s.assistant.snapshot().sources.find(v => v.id === 'boss'), previous);
});
