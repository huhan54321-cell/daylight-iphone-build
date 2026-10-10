'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { bossDocumentIssue } = require('../scripts/career-browser-records.cjs');

test('HTTP-success blank or returned pages cannot be accepted as BOSS login or jobs', () => {
  assert.equal(bossDocumentIssue('about:blank', '', true).state, 'blocked');
  assert.equal(bossDocumentIssue('https://example.com/', 'Previous page', true).state, 'blocked');
  assert.equal(bossDocumentIssue('https://www.zhipin.com/', '', true).state, 'error');
  assert.equal(bossDocumentIssue('https://www.zhipin.com.evil.example/', 'Jobs').state, 'blocked');
});

test('login page may be displayed for user authorization but cannot prove login success', () => {
  const url = 'https://www.zhipin.com/web/user/?ka=header-login';
  assert.equal(bossDocumentIssue(url, '扫码登录', true), null);
  assert.equal(bossDocumentIssue(url, '扫码登录').state, 'login_required');
  assert.equal(bossDocumentIssue('https://www.zhipin.com/web/geek/jobs', '登录后查看职位').state, 'login_required');
});

test('challenge pages stop even while preparing login; normal jobs remain readable', () => {
  assert.equal(bossDocumentIssue('https://www.zhipin.com/web/passport/zp/verify.html?code=36', '安全验证').state, 'blocked');
  assert.equal(bossDocumentIssue('https://www.zhipin.com/web/passport/zp/security.html', '验证', true).state, 'blocked');
  assert.equal(bossDocumentIssue('https://www.zhipin.com/', '请完成安全验证', true).state, 'blocked');
  assert.equal(bossDocumentIssue('https://www.zhipin.com/web/geek/jobs', '具身智能算法实习生 杭州'), null);
});
