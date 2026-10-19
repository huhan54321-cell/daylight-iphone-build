'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createCareerAssistant } = require('../scripts/career-assistant.cjs');
const domain = require('../scripts/career-assistant-domain.cjs');
const core = require('../scripts/career-core.cjs');
const { AssistantStore } = require('../scripts/career-assistant-store.cjs');
const stamp = '2026-10-19T02:00:00.000Z';
const raw = { company: '机器人团队', title: '机器人算法实习', city: '杭州', url: 'https://www.unitree.com/cn/position/1234', description: '机器人仿真与控制算法', requirements: ['Python'], verification: 'full_jd', minDays: 3, minMonths: 3 };
const job = () => core.normalizeJob(raw, 'unitree', stamp);
function note(id = 'a'.repeat(24), extra = {}) { return { id, url: `https://www.xiaohongshu.com/explore/${id}`, title: '机器人团队招聘实习生', text: '团队：机器人实验室\n地点：杭州\n要求每周三天，实习三个月。使用 Python 和 VLA。简历投递邮箱请查看原帖。', collectedAt: stamp, dateText: '2026-10-18', ...extra }; }
async function fixture(t, overrides = {}) {
  const root = path.resolve('.test-tmp'); fs.mkdirSync(root, { recursive: true });
  const dataDir = fs.mkdtempSync(path.join(root, 'assistant-'));
  const app = createCareerAssistant({ dataDir, xhsDir: path.join(dataDir, 'xhs'), now: () => stamp, cooldownMs: 0,
    getFeed: () => ({ ...core.initialFeed(), jobs: [job()] }), refreshJobs: async () => ({ ...core.initialFeed(), jobs: [job()] }),
    xhsRunner: () => ({ promise: Promise.resolve({ state: 'ok', notes: [note()], coverage: { detailsVisited: 1, partial: true } }), cancel() {} }), ...overrides });
  t.after(async () => { await app.close(); fs.rmSync(dataDir, { recursive: true, force: true }); });
  return app;
}
test('unknown, edited and yearless publication dates never become recent due to collection time', () => {
  const p = [domain.profile({})];
  for (const dateText of ['', '10-18', '编辑于 2026-10-18']) {
    const lead = domain.leadFromNote(note(undefined, { dateText }), p, null, stamp);
    assert.equal(lead.publishedDate, null); assert.equal(lead.dateBucket, 'unknown');
  }
  assert.equal(domain.leadFromNote(note(), p, null, stamp).dateBucket, 'recent');
});
test('seeking posts, experience and advertisements do not enter recruitment reports; image-only leads stay uncertain', () => {
  const p = [domain.profile({})];
  for (const title of ['求捞！机器人实习求职帖', '机器人实习面经', '机器人实习训练营保offer']) assert.equal(domain.leadFromNote(note(undefined, { title }), p, null, stamp).category, 'excluded');
  const l = domain.leadFromNote(note(undefined, { title: '机器人实习机会见图', text: '' }), p, null, stamp);
  assert.equal(l.category, 'insufficient'); assert.deepEqual(l.conditions, []);
});
test('migration is previewed, backed up, idempotent and never claims live source success', async t => {
  const a = await fixture(t); assert.equal(a.snapshot().jobs.length, 0);
  const p = await a.handle('GET', '/v2/career/migration'); assert.equal(p.jobs, 1);
  await assert.rejects(a.handle('POST', '/v2/career/migration', { previewID: 'stale' }), /重新预览/);
  const r = await a.handle('POST', '/v2/career/migration', { previewID: p.id }); assert.ok(r.backup.id);
  assert.equal(a.snapshot().jobs.length, 1);
  assert.equal((await a.handle('POST', '/v2/career/migration', { previewID: p.id })).imported, false);
});
test('new and changed posts are reported once; shorter refreshed closed text supersedes prior prose', async t => {
  const a = await fixture(t), config = domain.xhsConfig(a.snapshot().profiles, stamp);
  a.ingestNotes([note()], config, { id: 'one', state: 'ok', coverage: { detailsVisited: 1 } });
  a.ingestNotes([note()], config, { id: 'two', state: 'ok', coverage: { detailsVisited: 1 } });
  assert.equal(a.store.get('reports', 'two').leads.length, 0);
  await a.handle('POST', '/v2/career/leads/' + 'a'.repeat(24), { saved: true });
  a.ingestNotes([note(undefined, { text: '机器人实习已招满' })], config, { id: 'three', state: 'ok', recheck: true });
  const l = a.store.get('leads', 'a'.repeat(24)); assert.equal(l.category, 'closed'); assert.ok(l.saved); assert.ok(l.lastRecheckedAt);
  assert.equal(a.store.get('reports', 'three').closedIDs.length, 1);
});
test('listing refresh preserves complete JD and recommendation explains unknown conditions', async t => {
  const a = await fixture(t); a.syncFeed({ jobs: [job()] });
  a.syncFeed({ jobs: [core.normalizeJob({ ...raw, description: '简短摘要', verification: 'listing_only', minDays: null }, 'unitree', '2026-10-20T02:00:00Z')] });
  const j = a.snapshot().jobs[0]; assert.equal(j.description, raw.description); assert.equal(j.minDays, 3);
  assert.ok(j.matches[0].unknown.length); assert.equal(j.matches[0].lane, 'precise');
});
test('approved material version cannot execute after edits, double execution is idempotent and ambiguous result never retries', async t => {
  let executions = 0;
  const a = await fixture(t, { applicationAdapters: { unitree: { verifiedAt: stamp, inspect: async () => ({ hash: 'form-v1' }), submit: async () => { executions++; return { confirmed: false }; } } } });
  a.syncFeed({ jobs: [job()] });
  const m = await a.handle('POST', '/v2/career/materials', { title: '真实经历', content: '使用 Python 完成仿真项目', confirmedFacts: true });
  const prepared = await a.handle('POST', '/v2/career/applications', { jobID: job().id, materialID: m.id, action: 'submit', fields: { name: '测试用户' } });
  await a.handle('POST', `/v2/career/applications/${prepared.id}/approve`, { reviewHash: prepared.reviewHash, confirmed: true });
  await a.handle('POST', '/v2/career/materials', { id: m.id, title: m.title, content: '真实经历修订', confirmedFacts: true });
  await assert.rejects(a.handle('POST', `/v2/career/applications/${prepared.id}/execute`), /失效/);
  const updated = await a.handle('POST', '/v2/career/applications', { id: prepared.id, jobID: job().id, materialID: m.id, action: 'submit', fields: {} });
  await assert.rejects(a.handle('POST', `/v2/career/applications/${prepared.id}/approve`, { reviewHash: prepared.reviewHash, confirmed: true }), /变化/);
  await a.handle('POST', `/v2/career/applications/${updated.id}/approve`, { reviewHash: updated.reviewHash, confirmed: true });
  const results = await Promise.all([a.handle('POST', `/v2/career/applications/${updated.id}/execute`), a.handle('POST', `/v2/career/applications/${updated.id}/execute`)]);
  assert.equal(executions, 1); assert.equal(results[0].state, 'unknown');
  await a.handle('POST', `/v2/career/applications/${updated.id}/execute`); assert.equal(executions, 1);
});
test('one source failure does not prevent another source report, daily catch-up runs once', async t => {
  let jobRuns = 0;
  const a = await fixture(t, { refreshJobs: async () => { jobRuns++; throw new Error('blocked'); } });
  a.tick(); await a.waitForTask(); a.tick(); await a.waitForTask();
  assert.equal(jobRuns, 1); assert.equal(a.snapshot().leads.length, 1); assert.equal(a.snapshot().tasks[0].state, 'partial');
});
test('weekly saved lead recheck is bounded and no comments/images are requested', async t => {
  const calls = [];
  const a = await fixture(t, { xhsRunner: input => { calls.push(input); return { promise: Promise.resolve({ state: 'ok', notes: [], coverage: {} }), cancel() {} }; } });
  const config = domain.xhsConfig(a.snapshot().profiles, stamp);
  a.ingestNotes(Array.from({ length: 15 }, (_, i) => note(i.toString(16).padStart(24, '0'))), config, { id: 'seed', state: 'imported' });
  for (const lead of a.store.list('leads')) await a.handle('POST', '/v2/career/leads/' + lead.id, { saved: true });
  a.startRefresh({ sourceID: 'xiaohongshu' }); await a.waitForTask();
  assert.equal(calls.find(c => c.mode === 'recheck').config.recheckNotes.length, 10);
  assert.equal(calls[0].config.maxCommentsPerNote, 0); assert.equal(calls[0].config.collectImages, false);
});
test('SQLite restart preserves data and interrupted execution is unknown, never retried', async t => {
  const root = path.resolve('.test-tmp'); fs.mkdirSync(root, { recursive: true }); const d = fs.mkdtempSync(path.join(root, 'restart-'));
  const db = new AssistantStore(d); db.put('applications', { id: 'a', state: 'executing' }); db.put('tasks', { id: 't', state: 'running' }); db.close();
  const a = createCareerAssistant({ dataDir: d, now: () => stamp, getFeed: () => core.initialFeed() });
  t.after(async () => { await a.close(); fs.rmSync(d, { recursive: true, force: true }); });
  assert.equal(a.snapshot().applications[0].state, 'unknown'); assert.equal(a.snapshot().tasks[0].state, 'interrupted');
});
test('AI result cache prevents repeat calls and model failure preserves deterministic feed', async t => {
  let requests = 0;
  const a = await fixture(t, { analyze: async () => { requests++; return { summary: '建议', reasons: [], gaps: [], suggestions: [] }; } });
  a.syncFeed({ jobs: [job()] });
  const body = { jobID: job().id };
  await a.handle('POST', '/v2/career/ai', body); await a.handle('POST', '/v2/career/ai', body);
  assert.equal(requests, 1); assert.equal(a.snapshot().jobs.length, 1);
});
test('changed web form invalidates approval before submission and no platform action occurs', async t => {
  let form = 'v1', actions = 0;
  const a = await fixture(t, { applicationAdapters: { unitree: { verifiedAt: stamp, inspect: async () => ({ hash: form }), submit: async () => { actions++; } } } });
  a.syncFeed({ jobs: [job()] });
  const m = await a.handle('POST', '/v2/career/materials', { title: '材料', content: '真实经历', confirmedFacts: true });
  const p = await a.handle('POST', '/v2/career/applications', { jobID: job().id, materialID: m.id, action: 'submit' });
  await a.handle('POST', `/v2/career/applications/${p.id}/approve`, { reviewHash: p.reviewHash, confirmed: true });
  form = 'v2'; const result = await a.handle('POST', `/v2/career/applications/${p.id}/execute`);
  assert.equal(result.state, 'draft'); assert.equal(actions, 0);
});
test('restoring a backup retains history but clears executable approvals', async t => {
  const a = await fixture(t); a.syncFeed({ jobs: [job()] });
  const m = await a.handle('POST', '/v2/career/materials', { title: '材料', content: '真实经历', confirmedFacts: true });
  const p = await a.handle('POST', '/v2/career/applications', { jobID: job().id, materialID: m.id, action: 'submit' });
  await a.handle('POST', `/v2/career/applications/${p.id}/approve`, { reviewHash: p.reviewHash, confirmed: true });
  const archive = await a.handle('GET', '/v2/career/export');
  await a.handle('POST', '/v2/career/restore', archive);
  assert.equal(a.snapshot().applications[0].approvalHash, null); assert.equal(a.snapshot().jobs.length, 1);
  assert.equal(a.snapshot().applications[0].state, 'draft');
  assert.ok(fs.readdirSync(path.join(a.store.directory, 'backups')).length);
});
test('full-time and unknown employment types cannot be precise internship recommendations', () => {
  const match = domain.matchJob({ ...job(), title: '机器人算法工程师', jobType: '全职' }, domain.profile({}));
  assert.equal(match.lane, 'explore'); assert.ok(match.gaps.some(s => s.includes('实习')));
});

test('disabled profiles do not trigger fallback collection and malformed backups leave data intact', async t => {
  const a = await fixture(t);
  for (const p of a.store.list('profiles')) a.store.put('profiles', { ...p, enabled: false });
  assert.throws(() => a.startRefresh(), /启用/);
  const before = a.store.export().records;
  await assert.rejects(a.handle('POST', '/v2/career/restore', { schemaVersion: 2, records: [{ kind: 'reports', value: { id: 'bad' } }] }), /结构/);
  assert.deepEqual(a.store.export().records, before);
});

test('parallel preparation can create only one active application for a job', async t => {
  let inspectCalls = 0;
  const a = await fixture(t, { applicationAdapters: { unitree: { verifiedAt: stamp, inspect: async () => { inspectCalls++; await new Promise(resolve => setTimeout(resolve, 5)); return { hash: 'v1' }; }, submit: async () => ({}) } } });
  a.syncFeed({ jobs: [job()] });
  const m = await a.handle('POST', '/v2/career/materials', { title: '材料', content: '真实经历', confirmedFacts: true });
  const body = { jobID: job().id, materialID: m.id, action: 'submit' };
  const results = await Promise.allSettled([a.handle('POST', '/v2/career/applications', body), a.handle('POST', '/v2/career/applications', body)]);
  assert.equal(inspectCalls, 2); assert.equal(results.filter(r => r.status === 'fulfilled').length, 1); assert.equal(a.snapshot().applications.length, 1);
});
