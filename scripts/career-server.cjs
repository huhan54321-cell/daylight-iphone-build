'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { SOURCES, source, normalizeJob, mergeJobs, initialFeed, readFeed, writeFeed, publicFeed, applySourceResult, researchToJob } = require('./career-core.cjs');
const { boundedFetch, collectSource, SourceError } = require('./career-adapters.cjs');
const scheduler = require('./career-scheduler.cjs');
const { runBrowserCollector } = require('./career-browser-runner.cjs');
const details = require('./career-detail-queue.cjs');

function loadToken(dataDir, env) {
  if (env.CAREER_SERVICE_TOKEN) {
    if (env.CAREER_SERVICE_TOKEN.length < 24 || env.CAREER_SERVICE_TOKEN.length > 256) throw new Error('CAREER_SERVICE_TOKEN 必须为 24–256 字符的随机凭据');
    return env.CAREER_SERVICE_TOKEN;
  }
  const file = path.join(dataDir, 'token.txt');
  if (fs.existsSync(file)) { const token = fs.readFileSync(file, 'utf8').trim(); if (token.length < 24 || token.length > 256) throw new Error('本地服务凭据文件无效'); return token; }
  const token = crypto.randomBytes(32).toString('base64url');
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(file, token + '\n', { mode: 0o600, flag: 'wx' });
  // Git protection travels with the private cache, even when this folder is moved.
  fs.writeFileSync(path.join(dataDir, '.gitignore'), '*\n', { mode: 0o600 });
  return token;
}
function authorized(header, token) {
  const provided = typeof header === 'string' && header.startsWith('Bearer ') ? header.slice(7) : '';
  const a = Buffer.from(provided), b = Buffer.from(token);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
function readBody(req, maximum = 512 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0, chunks = [];
    if (Number(req.headers['content-length'] || 0) > maximum) { req.resume(); reject(Object.assign(new Error('请求正文过大'), { status: 413 })); return; }
    req.on('data', chunk => { size += chunk.length; if (size > maximum) { chunks = []; reject(Object.assign(new Error('请求正文过大'), { status: 413 })); } else chunks.push(chunk); });
    req.on('end', () => { try { resolve(size ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); } catch { reject(Object.assign(new Error('请求应为 JSON'), { status: 400 })); } });
    req.on('error', reject);
  });
}
function bootstrap(dataDir, seedFile) {
  const feed = readFeed(dataDir);
  // Add newly registered adapters without losing previous source errors or timestamps.
  for (const provider of SOURCES) if (!feed.sources.some(s => s.id === provider.id)) feed.sources.push(initialFeed().sources.find(s => s.id === provider.id));
  if (!feed.jobs.length && seedFile && fs.existsSync(seedFile)) {
    const raw = JSON.parse(fs.readFileSync(seedFile, 'utf8'));
    const rows = Array.isArray(raw) ? raw : raw.jobs;
    if (!Array.isArray(rows) || rows.length > 1500) throw new Error('初始岗位资料格式无效');
    const jobs = rows.map(row => row.sourceID ? normalizeJob(row, row.sourceID, row.checkedAt) : researchToJob(row, feed.generatedAt));
    feed.jobs = mergeJobs([], jobs);
    // Hand-checked bootstrap facts are not evidence of automated source success.
    feed.sources = feed.sources.map(s => ({ ...s, count: jobs.filter(j => j.sourceID === s.id).length, message: s.message + ' 已保留人工核查缓存，尚未自动核查。' }));
    writeFeed(dataDir, feed);
  }
  return feed;
}
function createCareerService(options = {}) {
  const dataDir = options.dataDir || path.resolve(__dirname, '../data/career-private');
  const env = options.env || process.env;
  const token = options.token || loadToken(dataDir, env);
  let feed = bootstrap(dataDir, options.seedFile);
  let queue = Promise.resolve(), refreshing = null, lastRefreshAt = 0;
  const now = options.now || (() => new Date().toISOString());
  let config = options.config ? scheduler.normalizeConfig(options.config) : scheduler.loadConfig(dataDir);
  let scheduleState = scheduler.loadScheduler(dataDir, now()), scheduleTimer = null;
  let detailQueue = details.loadQueue(dataDir);
  const buckets = new Map();
  const origins = new Set(['http://127.0.0.1:4173', 'http://localhost:4173', ...(env.CAREER_ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean)]);
  function viewFeed() {
    return { ...publicFeed(feed, now()), scheduler: { enabled: config.schedulingEnabled, running: Boolean(refreshing), intervalHours: config.intervalHours, nextRunAt: scheduleState.nextRunAt, lastRunAt: scheduleState.lastRunAt, lastFinishedAt: scheduleState.lastFinishedAt,
      budgetDay: scheduleState.daily.day, budgetUsed: scheduleState.daily.requests, budgetLimit: config.dailyRequestBudget, hostRequired: true, detailQueuePending: detailQueue.filter(row => row.state === 'pending' || row.state === 'error').length, detailQueueUnreadable: detailQueue.filter(row => row.state === 'unreadable' || row.state === 'blocked').length } };
  }
  const enqueue = fn => { const current = queue.then(fn); queue = current.catch(() => {}); return current; };
  function rateAllowed(req) {
    const key = req.socket.remoteAddress || 'local', stamp = Date.now();
    const previous = buckets.get(key);
    const bucket = previous && stamp - previous.since < 60000 ? previous : { since: stamp, count: 0 };
    bucket.count++; buckets.set(key, bucket);
    if (buckets.size > 200) for (const [ip, item] of buckets) if (stamp - item.since >= 60000) buckets.delete(ip);
    return bucket.count <= 80;
  }
  async function refresh(force = true) {
    if (refreshing) return refreshing;
    if (Date.now() - lastRefreshAt < (options.refreshCooldown ?? 60000)) throw Object.assign(new Error('请至少间隔一分钟刷新，避免重复请求招聘站'), { status: 429 });
    lastRefreshAt = Date.now();
    refreshing = enqueue(async () => {
      if (!options.config) config = scheduler.loadConfig(dataDir);
      scheduleState.lastRunAt = now();
      let runRequests = 0;
      const start = scheduleState.sourceCursor || 0;
      const providers = [...SOURCES.slice(start), ...SOURCES.slice(0, start)];
      for (const provider of providers) {
        const stamp = now();
        if (config.sources[provider.id] === false || !scheduler.shouldAttempt(scheduleState, provider.id, stamp, force)) continue;
        const planned = scheduler.queryPlan(config, scheduleState.sources[provider.id]?.queryCursor || {}, scheduleState.sources[provider.id]?.queryPages || {});
        let sourceRequests = 0;
        const searching = ['shixiseng','boss','tavily'].includes(provider.id);
        const coverage = { mode: searching ? 'search' : 'fixed_pages', cities: [], keywords: [], companies: [], plannedKeywords: searching ? planned.queries.map(q=>q.keyword) : [], plannedCompanies: searching ? planned.queries.map(q=>q.company).filter(Boolean) : [], totalQueries: searching ? planned.totalQueries : 0, queriesRun: 0, pagesRun: 0, detailsRun: 0, requests: 0, partial: true, nextCursor: planned.nextCursor };
        const spend = count => {
          if (runRequests + count > config.maxRequestsPerRefresh || !scheduler.spendBudget(scheduleState, config, now(), count)) throw new SourceError('error', '本次或每日采集预算已用完；旧结果保留，下轮按来源和查询轮转继续。');
          runRequests += count; sourceRequests += count; scheduler.saveScheduler(dataDir, scheduleState);
        };
        const request = options.request || boundedFetch(options.fetchImpl, { ...options.fetchOptions, maxRequests: Math.min(16, config.maxRequestsPerRefresh), onRequest: () => spend(1) });
        const queryEnv = { ...env, CAREER_QUERIES: planned.queries, CAREER_PAGES_PER_QUERY: config.pagesPerQuery, CAREER_MAX_DETAILS: config.maxDetailsPerSource, CAREER_DETAIL_CURSOR: scheduleState.sources[provider.id]?.detailCursor || 0 };
        let result;
        try {
          if (provider.id === 'boss' && config.browserCollectorEnabled && !options.collect) {
            // Reserve a conservative page/detail allowance; static browser assets are outside this budget.
            spend(planned.queries.length * config.pagesPerQuery + config.maxDetailsPerSource);
            result = await runBrowserCollector(dataDir, planned.queries, config);
          } else result = await (options.collect || collectSource)(provider.id, request, queryEnv, stamp);
        }
        catch (error) { result = { state: error.state || 'error', jobs: [], message: error.state ? error.message : '来源采集失败，已保留上次岗位。请查看配置和来源状态。' }; }
        Object.assign(coverage, result.coverage || {}, { requests: sourceRequests });
        if (searching && coverage.queriesRun > 0) {
          const attempted = planned.queries.slice(0, Math.min(coverage.queriesRun, planned.queries.length));
          coverage.cities = [...new Set(attempted.map(q=>q.city))]; coverage.keywords = attempted.map(q=>q.keyword); coverage.companies = attempted.map(q=>q.company).filter(Boolean);
        }
        if (provider.id === 'tavily' && result.jobs?.length) { details.addDiscoveries(detailQueue, result.jobs, stamp); details.saveQueue(dataDir, detailQueue); }
        result.coverage = coverage;
        // Normalize the whole source snapshot before any mutation; malformed records never clear old jobs.
        try { if (result.jobs?.length || result.state === 'ok') result.jobs.forEach(job => normalizeJob(job, provider.id, job.checkedAt || stamp)); applySourceResult(feed, provider.id, result, stamp); }
        catch { applySourceResult(feed, provider.id, { state: 'error', jobs: [], message: '来源字段无效，未覆盖上次结果。' }, stamp); }
        scheduler.recordAttempt(scheduleState, provider.id, result, stamp, config, coverage);
        const control = scheduleState.sources[provider.id];
        feed.sources = feed.sources.map(s => s.id === provider.id ? { ...s, nextAttemptAt: control.nextAttemptAt, failureCount: control.failureCount } : s);
        scheduler.saveScheduler(dataDir, scheduleState);
        writeFeed(dataDir, feed);
      }
      if (detailQueue.length && runRequests < config.maxRequestsPerRefresh && scheduler.remainingBudget(scheduleState, config, now()) > 0 && !options.collect) {
        const request = options.request || boundedFetch(options.fetchImpl, { ...options.fetchOptions, maxRequests: 2, onRequest: () => {
          if (runRequests >= config.maxRequestsPerRefresh || !scheduler.spendBudget(scheduleState, config, now(), 1)) throw new SourceError('error', '详情核查预算已用完');
          runRequests++; scheduler.saveScheduler(dataDir, scheduleState);
        } });
        const result = await details.processQueue(detailQueue, request, now(), 2);
        if (result.jobs.length) feed.jobs = mergeJobs(feed.jobs, result.jobs);
        details.saveQueue(dataDir, detailQueue); writeFeed(dataDir, feed);
      }
      scheduleState.sourceCursor = (start + 1) % SOURCES.length;
      scheduleState.lastFinishedAt = now(); scheduleState.nextRunAt = scheduler.nextRunAt(scheduleState, config, now());
      scheduler.saveScheduler(dataDir, scheduleState);
      return viewFeed();
    }).finally(() => { refreshing = null; });
    return refreshing;
  }
  const server = http.createServer(async (req, res) => {
    const origin = req.headers.origin;
    const headers = { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };
    if (origin && origins.has(origin)) { headers['Access-Control-Allow-Origin'] = origin; headers.Vary = 'Origin'; }
    function reply(code, value) { if (!res.writableEnded) { res.writeHead(code, headers); res.end(JSON.stringify(value)); } }
    try {
      if (origin && !origins.has(origin)) return reply(403, { error: '不允许此网页来源访问本地服务' });
      if (!rateAllowed(req)) return reply(429, { error: '请求频率过高' });
      if (req.method === 'OPTIONS') { headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'; headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'; return reply(204, {}); }
      const route = new URL(req.url, 'http://localhost').pathname;
      if (req.method === 'GET' && route === '/health') return reply(200, { status: 'ok', service: 'daylight-career', schemaVersion: 1 });
      if (!authorized(req.headers.authorization, token)) return reply(401, { error: '需要有效的服务连接凭据' });
      if (req.method === 'GET' && route === '/v1/career/feed') return reply(200, viewFeed());
      if (req.method === 'POST' && route === '/v1/career/refresh') {
        await readBody(req, 4096);
        if (refreshing) return reply(429, { error: '岗位采集正在运行，请读取当前进度后稍后刷新' });
        if (Date.now() - lastRefreshAt < (options.refreshCooldown ?? 60000)) return reply(429, { error: '请至少间隔一分钟刷新，避免重复请求招聘站' });
        refresh().catch(() => {});
        return reply(202, viewFeed());
      }
      if (req.method === 'POST' && route === '/v1/career/import') {
        const body = await readBody(req);
        if (!source(body.sourceID) || !Array.isArray(body.jobs) || !body.jobs.length || body.jobs.length > 100) return reply(400, { error: '指定已注册来源和 1–100 条规范岗位记录' });
        const stamp = now();
        const jobs = body.jobs.map(raw => normalizeJob(raw, body.sourceID, raw.checkedAt || stamp));
        const result = await enqueue(async () => {
          // Authorized local imports append; they are not complete source snapshots.
          feed.jobs = mergeJobs(feed.jobs, jobs);
          feed.generatedAt = stamp;
          feed.sources = feed.sources.map(s => s.id !== body.sourceID ? s : { ...s, state: 'ok', lastAttemptAt: stamp, lastSuccessAt: stamp, count: feed.jobs.filter(j => j.sourceID === s.id).length, message: `${jobs.length} 条本机授权采集记录已导入；不是全站覆盖。` });
          writeFeed(dataDir, feed);
          return viewFeed();
        });
        return reply(200, result);
      }
      if (req.method === 'POST' && route === '/v1/career/collector-status') {
        const body = await readBody(req, 4096);
        if (!['boss', 'shixiseng-public'].includes(body.sourceID) || !['login_required', 'blocked', 'error'].includes(body.state)) return reply(400, { error: '采集器只能记录受限来源的登录、验证或错误状态' });
        const stamp = now();
        const result = await enqueue(async () => {
          applySourceResult(feed, body.sourceID, { state: body.state, jobs: [], message: String(body.message || '本机采集未完成，已有记录保留').slice(0, 300) }, stamp);
          writeFeed(dataDir, feed); return viewFeed();
        });
        return reply(200, result);
      }
      return reply(404, { error: '接口不存在' });
    } catch (error) { return reply(error.status || 400, { error: error.status ? error.message : '岗位记录或请求无效；旧资料已保留。' }); }
  });
  server.requestTimeout = 20000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 5000;
  function stopScheduler() { if (scheduleTimer) clearTimeout(scheduleTimer); scheduleTimer = null; }
  function startScheduler() {
    stopScheduler();
    if (!config.schedulingEnabled) return;
    const delay = Math.max(1000, Math.min(3600000, Date.parse(scheduleState.nextRunAt) - Date.parse(now())));
    scheduleTimer = setTimeout(async () => {
      try { if (Date.parse(scheduleState.nextRunAt) <= Date.parse(now())) await refresh(false); }
      catch { scheduleState.nextRunAt = new Date(Date.parse(now()) + config.intervalHours * 3600000).toISOString(); scheduler.saveScheduler(dataDir, scheduleState); }
      finally { startScheduler(); }
    }, delay);
    scheduleTimer.unref();
  }
  server.on('close', stopScheduler);
  return { server, refresh, waitForRefresh: () => refreshing || Promise.resolve(viewFeed()), getFeed: viewFeed, startScheduler, stopScheduler, dataDir };
}
if (require.main === module) {
  const args = process.argv.slice(2);
  function value(flag) { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : null; }
  const dataDir = path.resolve(value('--data-dir') || path.join(__dirname, '../data/career-private'));
  const seedFile = path.resolve(value('--seed') || path.join(__dirname, '../ios/Daylight/CareerSeed.json'));
  const service = createCareerService({ dataDir, seedFile });
  const port = Number(value('--port') || process.env.CAREER_PORT || 4176);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('端口应为 1024–65535');
  service.server.listen(port, args.includes('--lan') ? '0.0.0.0' : '127.0.0.1', () => {
    console.log(`岗位接收服务：http://127.0.0.1:${port}，${args.includes('--lan') ? '允许同一局域网访问' : '只允许本机访问'}`);
    console.log(`连接凭据保存在 ${path.join(dataDir, 'token.txt')}；请在 App 服务连接中填写，不要上传此目录。`);
    if (!args.includes('--no-schedule')) {
      service.startScheduler();
      const hours = service.getFeed().scheduler.intervalHours;
      console.log(`已启用持久化周期采集，每 ${hours % 24 === 0 ? hours / 24 + ' 天' : hours + ' 小时'}；电脑服务需保持运行。`);
    }
  });
  service.server.on('error', error => { console.error(error.code === 'EADDRINUSE' ? '端口已占用，请使用 --port 指定其他端口。' : '服务启动失败。'); process.exitCode = 1; });
  if (args.includes('--refresh-on-start')) service.refresh().then(feed => console.log(`本次刷新结束：${feed.jobs.length} 条缓存岗位，详情见来源状态。`)).catch(() => console.error('刷新失败，服务继续提供原缓存。'));
}
module.exports = { createCareerService, loadToken, authorized, readBody, bootstrap };
