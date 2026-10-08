'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { extractConstraints, applyConstraints } = require('../scripts/career-constraints.cjs');
const { bossListRecord, bossDetailRecord } = require('../scripts/career-browser-records.cjs');
test('literal days months and graduation years become hard filters with evidence', () => {
  const result = extractConstraints('面向2027/2028届在校生；每周至少4天；至少连续实习6个月。');
  assert.equal(result.minDays, 4); assert.equal(result.minMonths, 6); assert.deepEqual(result.graduateYears, [2027,2028]); assert.ok(result.evidence.length >= 2);
});
test('preferred and uncertain statements never become hard eligibility', () => {
  const result = extractConstraints('2027届优先。每周4天为主。实习6个月最好。博士学历加分。');
  assert.equal(result.minDays, null); assert.equal(result.minMonths, null); assert.equal(result.requiredDegree, null); assert.deepEqual(result.graduateYears, []);
});
test('business dates and out-of-range values do not become employment constraints', () => {
  const result = extractConstraints('公司2026年10月6日成立。每周8天。至少25个月。2026-10-06开学。');
  assert.equal(result.minDays, null); assert.equal(result.minMonths, null); assert.deepEqual(result.graduateYears, []);
});
test('explicit PhD only differs from master-or-PhD or preferred PhD', () => {
  assert.equal(extractConstraints('仅限博士在读。').requiredDegree, 'phd');
  assert.equal(extractConstraints('学历要求：硕士或博士。').requiredDegree, 'master');
  assert.equal(extractConstraints('本科及以上，博士优先。').requiredDegree, 'bachelor');
  assert.equal(extractConstraints('团队导师拥有博士学历。').requiredDegree, null);
  assert.equal(extractConstraints('学历要求：博士及以上。').requiredDegree, 'phd');
});
test('platform explicit fields take priority over literal fallback', () => {
  const value = applyConstraints({ minDays: 5, minMonths: 3, graduateYears: [2028] }, '每周至少4天，实习6个月；仅2027届。');
  assert.equal(value.minDays, 5); assert.equal(value.minMonths, 3); assert.deepEqual(value.graduateYears, [2028]);
});
test('BOSS full JD extracts explicit eligibility while a listing stays unknown', () => {
  const list = bossListRecord({ brandName: '示例公司', jobName: '机器人实习生', cityName: '杭州', encryptJobId: 'example' }, '2026-10-06T02:00:00Z');
  const full = bossDetailRecord(list, { description: '面向2027/2028届在校生。每周至少4天，至少实习6个月。负责机器人仿真与模仿学习算法研发、闭环验证和数据采集，要求熟练Python与PyTorch。'.repeat(2) }, '2026-10-06T02:10:00Z');
  assert.equal(list.minDays, null); assert.equal(full.minDays, 4); assert.equal(full.minMonths, 6); assert.deepEqual(full.graduateYears, [2027,2028]); assert.match(full.sourceNote, /正文明确条件/);
});
