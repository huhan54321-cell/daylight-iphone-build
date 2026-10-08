'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { once } = require('node:events');
const crypto = require('node:crypto');
const core = require('../scripts/career-core.cjs');
const adapters = require('../scripts/career-adapters.cjs');
const { createCareerService, loadToken } = require('../scripts/career-server.cjs');
const { bossListRecord, bossResponseRecords, bossDetailRecord, validServiceURL } = require('../scripts/career-browser-records.cjs');
const stamp = '2026-10-06T02:00:00.000Z';
const raw = { company: '宇树科技', title: '机器人算法实习生', city: '杭州', jobType: '实习', url: 'https://www.unitree.com/cn/position/1234', description: '机器人与模仿学习算法', status: 'unconfirmed', requirements: [], relatedURLs: [] };
function job(change = {}, sourceID = 'unitree', time = stamp) { return core.normalizeJob({ ...raw, ...change }, sourceID, time); }

test('fixed public page reads and unexecuted plans never pretend keyword or company scans ran', async t => {
  const fixture = '<a href="/cn/position/1234"><p class="title">机器人算法实习生</p><p class="base-info">杭州市 | 在读</p><div class="duty">模仿学习算法研发</div></a>';
  const result = await adapters.collectSource('unitree', async () => fixture, {}, stamp);
  assert.equal(result.coverage.mode, 'fixed_pages');
  assert.equal(result.coverage.pagesRun, 1); assert.deepEqual(result.coverage.keywords, []);
  assert.deepEqual(result.coverage.companies, ['宇树科技']);
  const api = await service(t, { collect: async () => ({ state: 'not_configured', jobs: [], message: 'not configured' }) });
  await api.refresh();
  const boss = api.getFeed().sources.find(s=>s.id==='boss').coverage;
  assert.equal(boss.queriesRun, 0); assert.deepEqual(boss.keywords, []); assert.deepEqual(boss.companies, []);
  assert.ok(boss.plannedKeywords.length > 0);
  const fixed = api.getFeed().sources.find(s=>s.id==='unitree').coverage;
  assert.equal(fixed.totalQueries, 0); assert.equal(fixed.mode, 'fixed_pages');
});
function tempDir(t) { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'daylight-career-test-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; }
async function service(t, options = {}) {
  const instance = createCareerService({ dataDir: tempDir(t), token: 'test-credential-with-enough-randomness', now: () => stamp, refreshCooldown: 0, env: {}, ...options });
  instance.server.listen(0, '127.0.0.1'); await once(instance.server, 'listening');
  t.after(async () => { instance.server.closeAllConnections(); await new Promise(resolve => instance.server.close(resolve)); });
  const base = `http://127.0.0.1:${instance.server.address().port}`;
  async function request(route, body, auth = true, headers = {}) {
    const response = await fetch(base + route, { method: body === undefined ? 'GET' : 'POST', headers: { ...(auth ? { Authorization: 'Bearer test-credential-with-enough-randomness' } : {}), 'Content-Type': 'application/json', ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, json: await response.json() };
  }
  return { ...instance, base, request };
}
test('date parsing uses China civil time, rejects impossible dates and preserves unknown dates', () => {
  assert.equal(core.dateISO('2026-10-06 10:30:00'), '2026-10-06T02:30:00.000Z');
  assert.equal(core.dateISO('2026-02-30'), null);
  assert.equal(core.dateISO(null), null);
  assert.equal(core.deadlineISO('2026-10-06'), '2026-10-06T15:59:59.000Z');
});
test('historic publication, refreshed time and expiry are distinct', () => {
  const record = job({ publishedAt: '2026-03-02 09:00:00', refreshedAt: '2026-10-05', deadline: '2026-11-30', status: 'historical' });
  assert.equal(record.status, 'historical');
  assert.notEqual(record.publishedAt, record.refreshedAt);
  assert.equal(job({ deadline: '2026-09-20', status: 'verified' }).status, 'closed');
  assert.equal(core.publicFeed({ jobs: [job({ deadline: '2026-10-06' })] }, '2026-10-06T16:00:01Z').jobs[0].status, 'closed');
});
test('same posting merges across sources without merging internship and permanent roles', () => {
  const detail = { description: '负责机器人仿真与模仿学习算法开发，使用Python、PyTorch与MuJoCo完成闭环控制测试和数据采集流程。', verification: 'full_jd', requirements: ['Python与MuJoCo实际经验'] };
  const original = job(detail);
  const boss = job({ ...detail, company: '杭州宇树科技有限公司', url: 'https://www.zhipin.com/job_detail/abcd.html' }, 'boss');
  const merged = core.mergeJobs([], [original, boss]);
  assert.equal(merged.length, 1); assert.equal(merged[0].relatedURLs.length, 1);
  assert.equal(core.mergeJobs(merged, [boss])[0].id, merged[0].id);
  assert.equal(core.mergeJobs(merged, [job({ title: '机器人算法工程师', jobType: '全职', url: 'https://www.unitree.com/cn/position/5678' })]).length, 2);
  assert.doesNotThrow(() => core.normalizeJob(merged[0], merged[0].sourceID, stamp));
});
test('failed source retains last jobs, count and last success', () => {
  const feed = core.initialFeed(stamp);
  core.applySourceResult(feed, 'unitree', { state: 'ok', jobs: [raw], message: 'ok' }, stamp);
  core.applySourceResult(feed, 'unitree', { state: 'blocked', jobs: [], message: 'verification required' }, '2026-10-07T02:00:00Z');
  assert.equal(feed.jobs.length, 1);
  const source = feed.sources.find(s => s.id === 'unitree');
  assert.equal(source.count, 1); assert.equal(source.lastSuccessAt, stamp); assert.equal(source.state, 'blocked');
});
test('old verified cache becomes unconfirmed and a search excerpt cannot reopen closed jobs', () => {
  assert.equal(core.publicFeed({ jobs: [job({ status: 'verified' })] }, '2026-10-15T02:00:00Z').jobs[0].status, 'unconfirmed');
  const closed = job({ status: 'closed' });
  const snippet = job({ status: 'unconfirmed' }, 'tavily', '2026-10-07T02:00:00Z');
  assert.equal(core.mergeJobs([closed], [snippet]).find(j => j.sourceID === 'unitree').status, 'closed');
});
test('source URL validation blocks SSRF, credentials and misleading host suffixes', () => {
  for (const url of ['http://www.unitree.com/jobs', 'https://127.0.0.1/jobs', 'https://www.unitree.com.evil.test/jobs', 'https://secret@www.unitree.com/jobs', 'https://www.unitree.com:8443/jobs']) assert.throws(() => job({ url }));
  assert.equal(core.safeURL('https://m.zhipin.com/job_detail/abcd.html?utm_source=ad', 'boss'), 'https://www.zhipin.com/job_detail/abcd.html');
});
test('Unitree HTML extracts only real relevant titles and does not infer an internship', () => {
  const html = `<a href="/cn/position/1234"><p class="title">具身智能软件工程师 <span>热招</span></p><p class="base-info">杭州市 | 技术类 | 研发部</p><div class="duty"><p>模型部署。</p></div></a><a href="/cn/position/5678"><p class="title">销售经理</p><p class="base-info">杭州市 | 销售</p></a>`;
  const result = adapters.parseUnitree(html, stamp);
  assert.equal(result.length, 1); assert.equal(result[0].title, '具身智能软件工程师');
  assert.equal(result[0].jobType, '类型未注明'); assert.equal(result[0].publishedAt, null); assert.equal(result[0].verification, 'listing_only');
  assert.throws(() => adapters.parseUnitree('<html>login page</html>', stamp), /结构变化/);
});
test('ZJU extracts salary, constraints and publication without treating historic event as fresh', () => {
  const html = `<h3>杭州群核信息技术有限公司</h3><div class="post post-list zp-info-list"><h4><a href="/job?zpxxbh=abc">科研算法实习生（具身智能方向）</a></h4><p class="zp-info-left-detail"><span>面议</span><span>浙江省杭州市拱墅区</span><span>实习</span><span>本科及以上</span></p><p class="zp-info-right-time">2026-03-02 09:04:35</p><button onclick="checkGwsq('abc','2026-11-30')">投递</button><div class="post-des"><p>岗位描述：</p><p>仿真开发</p><p>岗位要求：</p><p>熟悉Python</p><p>6个月以上</p></div></div>`;
  const record = core.normalizeJob(adapters.parseZJU(html, stamp)[0], 'zju', stamp);
  assert.equal(record.status, 'unconfirmed'); assert.equal(record.minMonths, 6); assert.equal(record.requirements.length, 2); assert.equal(record.verification, 'full_jd');
});
test('Shixi HTML parser ignores huge inline styles and catches an explicitly closed low-value opening', () => {
  const html = `<title>机器人仿真实习生实习招聘-Palatial Technology实习生招聘-实习僧</title><style>${'css '.repeat(80000)}</style><div class="intern-detail-page"><div class="job_msg"><span class="job_position">杭州</span><span>5天／周 实习3个月</span></div><div class="resume_apply">当前职位已下线</div><div class="job_detail"><p>机器人仿真开发</p><p>要求Python和MuJoCo</p></div><div class="job_request">截止日期：2026-09-20</div></div>`;
  const record = adapters.parseShixiPublic(html, 'https://www.shixiseng.com/intern/inn_example', stamp);
  assert.equal(record.company, 'Palatial Technology'); assert.equal(record.status, 'closed'); assert.equal(record.minDays, 5); assert.equal(record.minMonths, 3); assert.match(record.description, /MuJoCo/); assert.equal(record.deadline, '2026-09-20');
});
test('Shixi official API uses documented authorization, form params and actual expiry', async () => {
  const env = { SHIXISENG_APP_ID: 'app123', SHIXISENG_APP_SECRET: 'secret456' }, calls = [];
  const request = async (url, settings) => {
    calls.push({ url, settings });
    const params = new URLSearchParams(settings.body), [appID, seconds] = Buffer.from(settings.headers.Authorization, 'base64').toString().split(':');
    assert.equal(appID, env.SHIXISENG_APP_ID);
    assert.equal(params.get('sign'), crypto.createHash('md5').update(appID + env.SHIXISENG_APP_SECRET + seconds).digest('hex').toUpperCase());
    assert.match(settings.headers['Content-Type'], /application\/x-www-form-urlencoded/);
    return JSON.stringify({ code: 100, msg: url.endsWith('/intern/search') ? [{ uuid: 'inn_example', name: '机器人算法实习生', company_name: '示例公司', city: '杭州', build_time: '2026-10-01 09:00:00', effective_time: '2026-11-30 09:00:00', status: 'normal' }] : { iname: '机器人算法实习生', cname: '示例公司', city: '杭州', day: 4, month: 3, info: '<p>机器人控制与仿真开发</p>', endtime: '2026-09-30 18:00:00', overdue: '1' } });
  };
  const result = await adapters.collectShixiAPI(request, env, stamp);
  assert.equal(calls.length, 4); assert.equal(result.jobs.length, 1); assert.equal(result.jobs[0].status, 'closed'); assert.equal(result.jobs[0].minDays, 4);
  assert.equal((await adapters.collectShixiAPI(() => { throw new Error('must not request'); }, {}, stamp)).state, 'not_configured');
});
test('Shixi API invalid authorization errors are explicit and do not leak credentials', async () => {
  const result = await adapters.collectShixiAPI(async () => JSON.stringify({ code: 314, msg: 'secret accidentally in remote reply' }), { SHIXISENG_APP_ID: 'app', SHIXISENG_APP_SECRET: 'secret' }, stamp);
  assert.equal(result.state, 'blocked'); assert.ok(!result.message.includes('secret'));
});
test('fetch budgets remain exhausted and response size and redirect whitelist are enforced', async () => {
  let calls = 0;
  const request = adapters.boundedFetch(async () => { calls++; return new Response('ok'); }, { maxRequests: 1, delay: 0 });
  assert.equal(await request('https://www.unitree.com/', {}, ['www.unitree.com']), 'ok');
  for (let n = 0; n < 2; n++) await assert.rejects(() => request('https://www.unitree.com/', {}, ['www.unitree.com']), /上限/);
  assert.equal(calls, 1);
  const large = adapters.boundedFetch(async () => new Response('abcde'), { maxBytes: 4, delay: 0 });
  await assert.rejects(() => large('https://www.unitree.com/', {}, ['www.unitree.com']), /大小上限/);
  const redirect = adapters.boundedFetch(async () => new Response('', { status: 302, headers: { location: 'http://127.0.0.1/secret' } }), { delay: 0 });
  await assert.rejects(() => redirect('https://www.unitree.com/', {}, ['www.unitree.com']), /允许的来源/);
});
test('BOSS response normalization records list clues without manufacturing full requirements', () => {
  const record = bossListRecord({ brandName: '宇树科技', jobName: '机器人算法实习生', cityName: '杭州', encryptJobId: 'abcd1234', salaryDesc: '200-300元/天', skills: ['Python'] }, stamp);
  assert.equal(record.verification, 'listing_only'); assert.equal(record.status, 'unconfirmed'); assert.equal(record.jobType, '实习'); assert.deepEqual(record.requirements, []);
  assert.equal(bossListRecord({ jobName: '职位缺公司', cityName: '杭州', encryptJobId: 'abcd' }, stamp), null);
  assert.equal(bossResponseRecords({ zpData: { jobList: [{ brandName: '宇树科技', jobName: '实习生', cityName: '杭州', encryptJobId: 'abcd' }] } }, stamp).length, 1);
  assert.equal(bossDetailRecord(record, { description: 'too short' }, stamp).verification, 'listing_only');
  assert.equal(bossDetailRecord(record, { description: '要求Python与机器人仿真。'.repeat(12), pageText: '职位已下线' }, stamp).status, 'closed');
});
test('collector service endpoint rejects remote plaintext and URL credentials', () => {
  assert.throws(() => validServiceURL('http://public.example/'));
  assert.throws(() => validServiceURL('https://token@public.example/'));
  assert.equal(validServiceURL('http://192.168.1.10:4176').port, '4176');
});
test('health is public and carries neither credentials nor private job content', async t => {
  const api = await service(t);
  const health = await api.request('/health', undefined, false);
  assert.equal(health.status, 200); assert.deepEqual(Object.keys(health.json).sort(), ['schemaVersion','service','status']);
  assert.equal((await api.request('/v1/career/feed', undefined, false)).status, 401);
  assert.equal((await api.request('/v1/career/feed', undefined, true, { Origin: 'https://evil.example' })).status, 403);
});
test('normalized authenticated imports persist and reject arbitrary fetch targets atomically', async t => {
  const api = await service(t);
  assert.equal((await api.request('/v1/career/import', { sourceID: 'unitree', jobs: [raw] }, false)).status, 401);
  assert.equal((await api.request('/v1/career/import', { sourceID: 'unitree', jobs: [raw, { ...raw, url: 'http://127.0.0.1/secret' }] })).status, 400);
  assert.equal(api.getFeed().jobs.length, 0);
  assert.equal((await api.request('/v1/career/import', { sourceID: 'unitree', jobs: [raw] })).status, 200);
  assert.equal(core.readFeed(api.dataDir).jobs.length, 1);
  await api.request('/v1/career/import', { sourceID: 'unitree', jobs: [raw] });
  assert.equal(api.getFeed().jobs.length, 1);
  assert.equal((await api.request('/v1/career/import', { sourceID: 'unitree', jobs: Array.from({ length: 101 }, () => raw) })).status, 400);
});
test('refresh reports failed sources without pretending old BOSS import disappeared', async t => {
  const api = await service(t, { collect: async id => id === 'unitree' ? { state: 'ok', jobs: [raw], message: 'ok' } : { state: 'login_required', jobs: [], message: 'needs login' } });
  const boss = { ...raw, url: 'https://www.zhipin.com/job_detail/otherjob.html', title: '机器人仿真实习生', company: '另一家公司' };
  await api.request('/v1/career/import', { sourceID: 'boss', jobs: [boss] });
  const response = await api.request('/v1/career/refresh', {});
  assert.equal(response.status, 202); await api.waitForRefresh(); assert.equal(api.getFeed().jobs.length, 2);
  const source = api.getFeed().sources.find(s => s.id === 'boss');
  assert.equal(source.state, 'login_required'); assert.equal(source.count, 1); assert.equal(source.lastSuccessAt, stamp);
});
test('malformed successful source results preserve jobs and become errors', async t => {
  const api = await service(t, { collect: async () => ({ state: 'ok', jobs: [{ company: 'missing title' }], message: 'not really successful' }) });
  await api.request('/v1/career/import', { sourceID: 'unitree', jobs: [raw] });
  await api.request('/v1/career/refresh', {});
  await api.waitForRefresh();
  assert.equal(api.getFeed().jobs.length, 1); assert.equal(api.getFeed().sources.find(s => s.id === 'unitree').state, 'error');
});
test('private token remains stable across restart and is not a pairing PIN', t => {
  const dir = tempDir(t), first = loadToken(dir, {});
  assert.ok(first.length >= 40); assert.equal(loadToken(dir, {}), first); assert.equal(fs.readFileSync(path.join(dir, '.gitignore'), 'utf8'), '*\n');
  assert.throws(() => loadToken(dir, { CAREER_SERVICE_TOKEN: '12345678' }));
});
test('bootstrap copies researched facts but does not claim live source synchronization', async t => {
  const dir = tempDir(t), seedFile = path.join(dir, 'public-seed.json');
  fs.writeFileSync(seedFile, JSON.stringify({ jobs: [{ ...raw, sourceID: 'unitree', checkedAt: stamp }] }));
  const api = await service(t, { seedFile });
  assert.equal(api.getFeed().jobs.length, 1); assert.equal(api.getFeed().sources.find(s => s.id === 'unitree').lastSuccessAt, null);
});
test('different source job IDs are kept separate even for identical titles and companies', () => {
  const first = job({ url: 'https://www.zhipin.com/job_detail/team1.html', minDays: 3 }, 'boss');
  const second = job({ url: 'https://www.zhipin.com/job_detail/team2.html', minDays: 5 }, 'boss');
  const merged = core.mergeJobs([], [first, second]);
  assert.equal(merged.length, 2); assert.notEqual(first.id, second.id);
});
test('listing refresh never overwrites full JD constraints or advances its last checked date', () => {
  const previous = job({ verification: 'full_jd', graduateYears: [2027], minDays: 5, minMonths: 6, requirements: ['2027届', '实习六个月'] });
  const listing = job({ verification: 'listing_only' }, 'unitree', '2026-10-07T02:00:00Z');
  const [merged] = core.mergeJobs([previous], [listing]);
  assert.equal(merged.minDays, 5); assert.equal(merged.minMonths, 6); assert.deepEqual(merged.graduateYears, [2027]); assert.equal(merged.checkedAt, stamp); assert.equal(merged.verification, 'full_jd');
});
test('recently refreshed verified long-running posting preserves its original publication', () => {
  const record = job({ status: 'verified', verification: 'full_jd', publishedAt: '2026-01-01', refreshedAt: '2026-10-06 09:00:00', deadline: '2026-12-31' });
  assert.equal(record.status, 'verified'); assert.equal(record.publishedAt, '2025-12-31T16:00:00.000Z');
  assert.equal(job({ status: 'verified', verification: 'full_jd', publishedAt: '2026-01-01', deadline: '2026-12-31' }).status, 'verified');
});
test('partial successful pages do not downgrade absent previously checked records', () => {
  const feed = core.initialFeed(stamp);
  core.applySourceResult(feed, 'unitree', { state: 'ok', jobs: [{ ...raw, status: 'verified' }] }, stamp);
  core.applySourceResult(feed, 'unitree', { state: 'ok', jobs: [], coverage: { partial: true } }, '2026-10-06T03:00:00Z');
  assert.equal(feed.jobs[0].status, 'verified'); assert.equal(feed.jobs[0].checkedAt, stamp);
});
test('partly blocked source keeps successfully captured listings without claiming successful full run', () => {
  const feed = core.initialFeed(stamp);
  core.applySourceResult(feed, 'boss', { state: 'blocked', jobs: [{ ...raw, url: 'https://www.zhipin.com/job_detail/captured.html', verification: 'listing_only' }], message: 'verification on detail' }, stamp);
  assert.equal(feed.jobs.length, 1); assert.equal(feed.sources.find(s => s.id === 'boss').lastSuccessAt, null); assert.equal(feed.sources.find(s => s.id === 'boss').state, 'blocked');
});
test('unrelated recommended closed card or city does not contaminate current Shixi posting', () => {
  const page = `<title>机器人实习生实习招聘-主公司实习生招聘-实习僧</title><div class="job_msg"><span class="job_position">上海</span><span>3天／周 实习6个月</span></div><div class="job_detail">机器人仿真开发，具备Python能力。</div><div class="job_request">截止日期：2026-12-31</div><div class="resume_apply">申请岗位</div><div>其他推荐：杭州 当前职位已下线 实习1个月</div>`;
  const result = adapters.parseShixiPublic(page, 'https://www.shixiseng.com/intern/inn_example', stamp);
  assert.equal(result.city, '上海'); assert.equal(result.status, 'unconfirmed'); assert.equal(result.minMonths, 6);
  assert.throws(() => adapters.parseShixiPublic(page.replace('<span class="job_position">上海</span>', ''), 'https://www.shixiseng.com/intern/inn_example', stamp), /未取得完整/);
});
test('same template with different requirements and same-source transitive aliases remain separate', () => {
  const base = { description: '负责机器人仿真、数据采集与模仿学习算法开发，使用Python与MuJoCo实现完整的闭环控制训练和验证实验流程。', verification: 'full_jd', url: 'https://www.zhipin.com/job_detail/bossA.html', requirements: ['必须熟练ROS2'] };
  const first = job(base, 'boss');
  const second = job({ ...base, url: 'https://www.shixiseng.com/intern/inn_b', requirements: ['仅ROS基础'] }, 'shixiseng-public');
  assert.equal(core.mergeJobs([first], [second]).length, 2);
  const matching = job({ ...base, url: 'https://www.shixiseng.com/intern/inn_c' }, 'shixiseng-public', '2026-10-07T02:00:00Z');
  const cluster = core.mergeJobs([first], [matching]);
  assert.equal(cluster.length, 1);
  const third = job({ ...base, url: 'https://www.zhipin.com/job_detail/bossD.html' }, 'boss', '2026-10-08T02:00:00Z');
  assert.equal(core.mergeJobs(cluster, [third]).length, 2);
});
test('m and www BOSS links share stable source identity while meaningful URL params and SPA route survive', () => {
  const a = job({ url: 'https://m.zhipin.com/job_detail/abcd.html?securityId=shortterm' }, 'boss');
  const b = job({ url: 'https://www.zhipin.com/job_detail/abcd.html' }, 'boss');
  assert.equal(a.id, b.id); assert.equal(core.mergeJobs([a], [b]).length, 1);
  assert.match(core.safeURL('https://www.unitree.com/jobs?source=jobA#/job/B', 'unitree'), /source=jobA#\/job\/B/);
});
test('refresh accepts asynchronously and prevents overlapping manual requests', async t => {
  let unblock;
  const wait = new Promise(resolve => { unblock = resolve; });
  const api = await service(t, { collect: async () => { await wait; return { state: 'ok', jobs: [], message: 'ok' }; } });
  const first = await api.request('/v1/career/refresh', {});
  assert.equal(first.status, 202); assert.equal(api.getFeed().scheduler.running, true);
  assert.equal((await api.request('/v1/career/refresh', {})).status, 429);
  unblock(); await api.waitForRefresh(); assert.equal(api.getFeed().scheduler.running, false);
});
test('Shixi query page checkpoint advances beyond page 3 while each run rediscovers page 1', async () => {
  const pages = [];
  const result = await adapters.collectShixiAPI(async (url, settings) => { const p = new URLSearchParams(settings.body); pages.push(Number(p.get('page'))); return JSON.stringify({ code: 100, msg: Array.from({ length: 20 }, (_, i) => ({ uuid: `inn_example${i}`, name: '机器人实习生', company_name: '示例公司', city: '杭州', status: 'normal' })) }); }, { SHIXISENG_APP_ID: 'app', SHIXISENG_APP_SECRET: 'secret', CAREER_QUERIES: [{ city: '杭州', keyword: '机器人', queryID: 'q1', pageStart: 4 }], CAREER_PAGES_PER_QUERY: 2, CAREER_MAX_DETAILS: 0 }, stamp);
  assert.deepEqual(pages, [1, 4]); assert.equal(result.coverage.queryPages.q1, 5); assert.equal(result.jobs.length, 20);
});
test('generic company recruitment page preserves separate job titles while exact posting title updates share identity', () => {
  const companyURL = 'https://www.career.zju.edu.cn/jyxt/sczp/zphgl/ckZphdwXq.zf?dwxxid=company123';
  const records = ['具身算法实习生','机器人仿真实习生','机器人系统实习生'].map(title => job({ company: '宇泛', title, url: companyURL }, 'zju'));
  assert.equal(core.mergeJobs([], records).length, 3);
  assert.equal(new Set(records.map(record => record.id)).size, 3);
  assert.equal(core.mergeJobs(records, records).length, 3);
  const original = job({ title: '机器人算法实习生', url: 'https://www.zhipin.com/job_detail/exactid.html' }, 'boss');
  const revision = job({ title: '具身操作算法实习生', url: 'https://www.zhipin.com/job_detail/exactid.html' }, 'boss', '2026-10-07T02:00:00Z');
  assert.equal(original.id, revision.id); assert.equal(core.mergeJobs([original], [revision]).length, 1);
});
