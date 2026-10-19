'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { parseShixiSearch, collectShixiSearch, parseOfficialStructured } = require('../scripts/career-public-discovery.cjs');
const html = '<div data-intern-id="inn_abc" class="intern-wrap"><div class="intern-detail__job"><a href="https://www.shixiseng.com/intern/inn_abc?pcm=search">机器人实习&#xe466;</a><span class="city ellipsis">杭州</span></div><div class="intern-detail__company"><a>机器人公司</a></div></div>';
test('public search preserves font uncertainty and never fabricates salary, age or duration', () => {
  const rows = parseShixiSearch(html); assert.equal(rows.length, 1); assert.equal(rows[0].title, '机器人实习□'); assert.equal(rows[0].company, '机器人公司'); assert.equal(rows[0].salary, '未注明'); assert.equal(rows[0].publishedAt, null);
  assert.throws(() => parseShixiSearch('<body>安全验证</body>'), /验证/);
  assert.throws(() => parseShixiSearch('<body>new layout</body>'), /不可读/);
});
test('partially failed discovery retains actual cards without claiming full JD', async () => {
  let count = 0;
  const r = await collectShixiSearch(async () => { if (++count === 1) return html; throw new Error('offline'); }, { CAREER_QUERIES: [{ keyword: '机器人', city: '杭州' }, { keyword: 'VLA', city: '上海' }] }, '2026-10-19T02:00:00Z');
  assert.equal(r.jobs.length, 1); assert.equal(r.jobs[0].verification, 'listing_only'); assert.equal(r.coverage.queriesRun, 1); assert.equal(r.state, 'error');
});
test('official structured jobs require complete evidence and an allowed actual posting URL', () => {
  const node = { '@type': 'JobPosting', title: '机器人实习', description: '真实正文', hiringOrganization: { name: '团队' }, jobLocation: { address: { addressLocality: '杭州' } }, url: 'https://careers.tencent.com/job/1' };
  const wrap = value => `<script type="application/ld+json">${JSON.stringify(value)}</script>`;
  assert.equal(parseOfficialStructured(wrap(node), node.url).length, 1);
  assert.equal(parseOfficialStructured(wrap({ ...node, url: 'http://127.0.0.1/secret' }), node.url).length, 0);
  assert.equal(parseOfficialStructured(wrap({ ...node, description: '' }), node.url).length, 0);
});
