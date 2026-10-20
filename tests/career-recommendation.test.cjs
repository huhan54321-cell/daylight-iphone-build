'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const domain = require('../scripts/career-assistant-domain.cjs');
const now = '2026-10-20T12:00:00Z';
const target = domain.profile({ cities: ['杭州', '上海深圳北京'] });
const job = { title: '具身智能算法实习生', jobType: '实习', city: '杭州', status: 'unconfirmed', verification: 'listing_only', checkedAt: now, description: '', requirements: [], tags: [] };
test('concatenated known cities split without guessing unknown regions', () => {
  assert.deepEqual(target.cities, ['杭州', '上海', '深圳', '北京']);
  assert.deepEqual(domain.cities(['长三角', '苏州工业园区', '成都、武汉']), ['长三角', '苏州工业园区', '成都', '武汉']);
  assert.equal(domain.matchJob({ ...job, city: '深圳' }, target, now).lane, 'precise');
});
test('new list-only internships qualify with uncertainties, incidental robot mention does not', () => {
  const listing = domain.matchJob(job, target, now);
  assert.equal(listing.lane, 'precise'); assert.ok(listing.unknown.includes('尚未取得完整岗位正文'));
  const incidental = domain.matchJob({ ...job, title: '农业传感器实习生', verification: 'full_jd', description: '研究农业传感器，可用于机器人。' }, target, now);
  assert.equal(incidental.lane, 'explore'); assert.ok(listing.score > incidental.score);
  assert.equal(domain.matchJob({ ...job, city: '南京' }, target, now).lane, 'explore');
  assert.equal(domain.matchJob({ ...job, title: '具身智能工程师', jobType: '全职' }, target, now).lane, 'explore');
  assert.equal(domain.matchJob({ ...job, status: 'closed' }, target, now).lane, 'explore');
});
test('stale validity is explicit and repeated checks do not masquerade as newly discovered', () => {
  assert.equal(domain.matchJob({ ...job, checkedAt: '2026-08-01T00:00:00Z' }, target, now).lane, 'explore');
  const old = { ...job, firstSeenAt: '2026-10-01T00:00:00Z', contentUpdatedAt: '2026-10-01T00:00:00Z' };
  assert.equal(domain.matchJob(old, target, now).score, domain.matchJob({ ...old, checkedAt: '2026-10-20T11:59:00Z' }, target, now).score);
  assert.ok(domain.matchJob(job, target, now).score > domain.matchJob(old, target, now).score);
});
