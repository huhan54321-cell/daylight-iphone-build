'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const schedule = require('../scripts/career-scheduler.cjs');
const stamp = '2026-10-06T02:00:00.000Z';
test('discovery does not require internship and all robotics aliases in the same search phrase', () => {
  const config = schedule.normalizeConfig(); const plan = schedule.queryPlan(config);
  assert.ok(config.keywords.includes('模仿学习') && config.keywords.includes('机械臂'));
  assert.ok(config.keywords.every(keyword=>!keyword.includes(' ') && !keyword.includes('实习')));
  const company = plan.queries.find(query=>query.company);
  assert.equal(company.keyword, company.company);
});
function temp(t) { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'daylight-career-schedule-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; }
test('query planning rotates skills and company coverage without inventing another city', () => {
  const config = schedule.normalizeConfig({ cities: ['杭州'], keywords: ['机器人操作', '模仿学习', '机器人仿真', '机器人系统'], companies: ['西湖机器人', '群核'], maxQueriesPerSource: 3 });
  const first = schedule.queryPlan(config, 0), second = schedule.queryPlan(config, first.nextCursor);
  assert.equal(first.totalQueries, 6); assert.equal(first.queries.length, 3); assert.equal(first.queries[1].company, '西湖机器人'); assert.equal(second.queries[1].company, '群核');
  assert.ok([...first.queries, ...second.queries].every(q => q.city === '杭州')); assert.equal(first.queries[0].keyword, '机器人操作'); assert.equal(second.queries[0].keyword, '机器人仿真');
});
test('daily quota resets at China midnight and exhausted budget cannot silently increase', () => {
  const config = schedule.normalizeConfig({ dailyRequestBudget: 10 });
  const state = { daily: { day: '2026-10-06', requests: 9 } };
  assert.equal(schedule.spendBudget(state, config, '2026-10-06T15:59:59Z'), true);
  assert.equal(schedule.spendBudget(state, config, '2026-10-06T15:59:59Z'), false); assert.equal(state.daily.requests, 10);
  assert.equal(schedule.remainingBudget(state, config, '2026-10-06T16:00:00Z'), 10); assert.equal(state.daily.day, '2026-10-07');
});
test('blocked sources back off exponentially while respecting a shorter configured cadence', () => {
  const config = schedule.normalizeConfig({ intervalHours: 1 }), state = { daily: { day: '2026-10-06', requests: 0 }, sources: {} };
  schedule.recordAttempt(state, 'boss', { state: 'blocked' }, stamp, config);
  assert.equal(state.sources.boss.nextAttemptAt, '2026-10-06T03:00:00.000Z');
  schedule.recordAttempt(state, 'boss', { state: 'blocked' }, '2026-10-06T03:00:00.000Z', config);
  assert.equal(state.sources.boss.nextAttemptAt, '2026-10-06T05:00:00.000Z');
  assert.equal(schedule.shouldAttempt(state, 'boss', '2026-10-06T04:00:00Z', false), false); assert.equal(schedule.shouldAttempt(state, 'boss', '2026-10-06T04:00:00Z', true), true);
  schedule.recordAttempt(state, 'shixiseng', { state: 'not_configured' }, stamp, config);
  assert.equal(state.sources.shixiseng.nextAttemptAt, '2026-10-07T02:00:00.000Z');
});

test('default automatic collection and failure retries wait three days while manual refresh remains available', () => {
  const config = schedule.normalizeConfig(), state = { daily: { day: '2026-10-06', requests: 0 }, sources: {} };
  assert.equal(config.intervalHours, 72);
  assert.equal(schedule.normalizeConfig({ intervalHours: 48 }).intervalHours, 48);
  for (const status of ['ok', 'blocked', 'error', 'login_required', 'not_configured']) {
    schedule.recordAttempt(state, status, { state: status }, stamp, config);
    assert.equal(state.sources[status].nextAttemptAt, '2026-10-09T02:00:00.000Z');
    assert.equal(schedule.shouldAttempt(state, status, '2026-10-07T02:00:00.000Z', false), false);
    assert.equal(schedule.shouldAttempt(state, status, '2026-10-07T02:00:00.000Z', true), true);
  }
  assert.equal(schedule.nextRunAt(state, config, stamp), '2026-10-09T02:00:00.000Z');
  // Persisted shorter source retries must not bring a global round forward.
  state.sources.error.nextAttemptAt = '2026-10-06T02:05:00.000Z';
  assert.equal(schedule.nextRunAt(state, config, stamp), '2026-10-09T02:00:00.000Z');
});
test('scheduler next run, per-source cursor and budget survive restart', t => {
  const directory = temp(t), config = schedule.loadConfig(directory);
  const state = schedule.loadScheduler(directory, stamp);
  state.daily.requests = 12; state.nextRunAt = '2026-10-06T08:00:00.000Z';
  schedule.recordAttempt(state, 'tavily', { state: 'ok' }, stamp, config, { nextCursor: { skill: 3, company: 2, other: 1 }, nextDetailCursor: 8, queryPages: { query123: 6 }, queriesRun: 3 });
  schedule.saveScheduler(directory, state);
  const restored = schedule.loadScheduler(directory, '2026-10-06T03:00:00Z');
  assert.equal(restored.nextRunAt, state.nextRunAt); assert.equal(restored.sources.tavily.queryCursor.skill, 3); assert.equal(restored.sources.tavily.detailCursor, 8); assert.equal(restored.sources.tavily.queryPages.query123, 6); assert.equal(restored.daily.requests, 12);
});
test('every default query batch includes a direction, a Hangzhou company and a separate other city', () => {
  const config = schedule.normalizeConfig();
  let cursor = {};
  for (let i = 0; i < 10; i++) { const plan = schedule.queryPlan(config, cursor); cursor = plan.nextCursor; assert.ok(plan.queries.some(q => q.city === '杭州' && q.company)); assert.ok(plan.queries.some(q => q.city === '杭州' && !q.company)); assert.ok(plan.queries.some(q => q.city === '上海')); }
});
test('config limits cap frequency, pages and requests despite oversized input', () => {
  const config = schedule.normalizeConfig({ intervalHours: 0, maxRequestsPerRefresh: 100000, pagesPerQuery: 100, maxQueriesPerSource: 100, companies: Array.from({ length: 200 }, (_, i) => String(i)) });
  assert.equal(config.intervalHours, 1); assert.equal(config.maxRequestsPerRefresh, 48); assert.equal(config.pagesPerQuery, 3); assert.equal(config.maxQueriesPerSource, 8); assert.equal(config.companies.length, 40);
});
