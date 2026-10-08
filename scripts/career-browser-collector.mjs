/** Optional, user-run collector. Reads a user's visible BOSS pages only.
 * No stealth flags, CAPTCHA bypass, chat, résumé access, or applications.
 * Requires separately installed official Playwright and Chromium. Not run by CI.
 */
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { mergeJobs, safeURL, contentHash } = require('./career-core.cjs');
const { loadConfig, queryPlan } = require('./career-scheduler.cjs');
const { bossListRecord, bossResponseRecords, bossDetailRecord, validServiceURL } = require('./career-browser-records.cjs');
const directory = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const value = flag => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : null; };
const sourceID = value('--source') || 'boss';
const dataDir = path.resolve(value('--data-dir') || path.join(directory, '../data/career-private'));
const profile = path.join(dataDir, 'browser-boss');
const endpoint = validServiceURL(value('--endpoint') || process.env.CAREER_SERVICE_URL || 'http://127.0.0.1:4176');
const tokenFile = path.join(dataDir, 'token.txt');
const token = process.env.CAREER_SERVICE_TOKEN || (fs.existsSync(tokenFile) ? fs.readFileSync(tokenFile, 'utf8').trim() : '');
let context;
let partialSaved = false;
let coverage = { queriesRun: 0, pagesRun: 0, detailsRun: 0, requests: 0, queryPages: {}, partial: true };
let finalState = 'error', finalMessage = '本机采集未完成';
class CollectorError extends Error { constructor(state, message) { super(message); this.state = state; } }
async function post(route, body) {
  if (!token || token.length < 24) throw new Error('请先启动自己的岗位服务取得连接凭据');
  const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15000);
  try {
    const response = await fetch(new URL(route, endpoint), { method: 'POST', redirect: 'error', signal: controller.signal, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
    if (!response.ok) throw new Error(`自己的岗位服务返回 HTTP ${response.status}`);
    return response.json();
  } finally { clearTimeout(timer); }
}
async function pageState(page) {
  const body = (await page.locator('body').innerText({ timeout: 8000 })).slice(0, 30000);
  if (/访问验证|安全验证|完成验证后|滑动.*验证|异常访问|验证您的身份/.test(body) || /verify|security-check|\/web\/passport\/zp\/security\.html/.test(page.url())) throw new CollectorError('blocked', 'BOSS 要求安全验证；采集已停止，请在自己的浏览器处理后重试。');
  if (/\/web\/user\//.test(page.url()) || /扫码登录后.*查看|请登录后.*查看|登录后查看职位/.test(body)) throw new CollectorError('login_required', 'BOSS 会话尚未登录或已过期，请运行 --login。');
  return body;
}
async function visibleDOMRows(page) {
  return page.locator('.job-card-wrapper, .job-card-box').evaluateAll(cards => cards.slice(0, 40).map(card => {
    const clean = selector => card.querySelector(selector)?.textContent?.trim() || '';
    const link = card.querySelector('a[href*="/job_detail/"]');
    return { title: clean('.job-name') || clean('.job-title'), company: clean('.company-name') || clean('.brand-name'), city: (clean('.job-area') || clean('.job-area-wrapper')).split(/[·•\s]/)[0].replace(/市$/, ''), salary: clean('.salary'), url: link?.href, jobExperience: clean('.job-info') };
  }));
}
async function collect(page) {
  const started = Date.now(), checkedAt = new Date().toISOString();
  let records = [], collectedResponses = 0, pending = [], challengeFromResponse = false, activeQuery = null, observedPages = new Map();
  const actionLimit = Math.max(2, Math.min(32, Number(process.env.CAREER_MAX_PAGE_ACTIONS) || 14));
  const spendAction = () => { if (coverage.requests >= actionLimit) throw new CollectorError('error', '本轮页面动作预算达到上限；已有部分数据和分页checkpoint已保存。'); coverage.requests++; };
  const listener = response => {
    const url = new URL(response.url());
    if (url.hostname !== 'www.zhipin.com' || !url.pathname.endsWith('/wapi/zpgeek/search/joblist.json') || collectedResponses >= 12) return;
    const query = activeQuery, pageNumber = Number(url.searchParams.get('page') || url.searchParams.get('pageIndex') || 0);
    collectedResponses++;
    const promise = (async () => {
      const size = Number(await response.headerValue('content-length') || 0);
      if (size > 2 * 1024 * 1024) return;
      const bytes = await response.body();
      if (bytes.length > 2 * 1024 * 1024) return;
      const json = JSON.parse(bytes.toString('utf8'));
      if ([37,42].includes(json.code)) { challengeFromResponse = true; return; }
      if (query?.queryID && pageNumber > 0 && Array.isArray(json?.zpData?.jobList)) observedPages.set(query.queryID, pageNumber);
      records = mergeJobs(records, bossResponseRecords(json, checkedAt));
    })().catch(() => {});
    pending.push(promise);
  };
  page.on('response', listener);
  try {
    const config = loadConfig(dataDir);
    const queries = process.env.CAREER_COLLECT_QUERIES ? JSON.parse(process.env.CAREER_COLLECT_QUERIES).slice(0, 8) : queryPlan(config).queries;
    const pagesPerQuery = Math.max(1, Math.min(3, Number(process.env.CAREER_PAGES_PER_QUERY) || config.pagesPerQuery));
    const cityCodes = { '杭州': '101210100', '北京': '101010100', '上海': '101020100' };
    for (const { keyword, city } of queries) {
      if (Date.now() - started > 90000) break;
      if (!cityCodes[city]) throw new CollectorError('error', `本机 BOSS 采集器暂未验证 ${city} 城市映射；未将其当作杭州结果。`);
      const url = new URL('https://www.zhipin.com/web/geek/jobs');
      url.searchParams.set('query', keyword); url.searchParams.set('city', cityCodes[city]);
      activeQuery = queries.find(q => q.keyword === keyword && q.city === city);
      spendAction(); await page.goto(url.href, { waitUntil: 'domcontentloaded', timeout: 25000 });
      coverage.queriesRun++;
      for (let number = 0; number < pagesPerQuery; number++) {
        await pageState(page);
        if (challengeFromResponse) throw new CollectorError('blocked', 'BOSS 返回安全验证响应；停止采集，保留旧结果。');
        await page.locator('.job-card-wrapper, .job-card-box').first().waitFor({ state: 'visible', timeout: 8000 }).catch(() => {});
        const rows = await visibleDOMRows(page);
        records = mergeJobs(records, rows.map(r => bossListRecord(r, checkedAt)).filter(Boolean));
        await Promise.allSettled(pending); pending = [];
        const actual = observedPages.get(activeQuery.queryID) || Number(await page.locator('.options-pages .selected, .options-pages .active, .ui-page-item-active').first().innerText({ timeout: 500 }).catch(() => '')) || (number === 0 ? 1 : 0);
        if (actual > 0) { coverage.pagesRun++; if (activeQuery.queryID) coverage.queryPages[activeQuery.queryID] = actual > 1 ? Math.min(100, actual + 1) : activeQuery.pageStart || 2; }
        if (records.length) await checkpoint(records);
        if (number === pagesPerQuery - 1 || Date.now() - started > 90000) break;
        const target = Math.max(2, activeQuery.pageStart || 2) + number;
        url.searchParams.set('page', String(target));
        spendAction(); await page.goto(url.href, { waitUntil: 'domcontentloaded', timeout: 20000 });
        await Promise.allSettled(pending); pending = [];
        let current = observedPages.get(activeQuery.queryID) || Number(await page.locator('.options-pages .selected, .options-pages .active, .ui-page-item-active').first().innerText({ timeout: 500 }).catch(() => '')) || 1;
        while (current < target && coverage.requests < actionLimit) {
          const next = page.locator('.options-pages a.next, .ui-icon-arrow-right, button[aria-label="下一页"]').first();
          if (!(await next.isVisible().catch(() => false)) || !(await next.isEnabled().catch(() => false))) { if (activeQuery.queryID) coverage.queryPages[activeQuery.queryID] = 2; break; }
          const previousPage = current;
          spendAction(); await next.click();
          await page.waitForFunction(old => Number(document.querySelector('.options-pages .selected, .options-pages .active, .ui-page-item-active')?.textContent) > old, current, { timeout: 3000 }).catch(() => {});
          await Promise.allSettled(pending); pending = [];
          current = observedPages.get(activeQuery.queryID) || Number(await page.locator('.options-pages .selected, .options-pages .active, .ui-page-item-active').first().innerText({ timeout: 500 }).catch(() => '')) || previousPage;
          await pageState(page);
          if (current <= previousPage) { coverage.deepPageUnverified = true; break; }
        }
        if (current < target) { coverage.deepPageUnverified = true; break; }
        const previous = rows.map(r => r.url).join('|');
        await page.waitForFunction(old => [...document.querySelectorAll('a[href*="/job_detail/"]')].slice(0, 40).map(a => a.href).join('|') !== old, previous, { timeout: 8000 }).catch(() => {});
      }
    }
  } finally { page.off('response', listener); await Promise.allSettled(pending); }
  if (!records.length) throw new CollectorError('error', '未取得公司、标题、城市和来源链接齐全的岗位。可能是登录、平台结构变化或无匹配结果；不将本次当作成功全量采集。');
  const config = loadConfig(dataDir), detailLimit = Math.max(0, Math.min(12, Number(process.env.CAREER_MAX_DETAILS) || config.maxDetailsPerSource));
  const cacheFile = path.join(dataDir, 'boss-detail-cache.json');
  let cache = fs.existsSync(cacheFile) ? JSON.parse(fs.readFileSync(cacheFile, 'utf8')) : {};
  // Unchanged list facts reuse old full JDs, retaining their original checkedAt; refresh each weekly.
  for (let i = 0; i < records.length; i++) {
    if (Date.now() - started > 90000) break;
    const record = records[i];
    const prior = cache[record.url];
    if (prior && prior.listHash === record.contentHash && Date.parse(checkedAt) - Date.parse(prior.detail.checkedAt) < 7 * 86400000) { records[i] = prior.detail; continue; }
    if (coverage.detailsRun >= detailLimit) continue;
    spendAction();
    await page.goto(safeURL(record.url, 'boss'), { waitUntil: 'domcontentloaded', timeout: 20000 });
    const pageText = await pageState(page);
    const description = await page.locator('.job-sec-text, .job-detail-section .text').first().innerText({ timeout: 5000 }).catch(() => '');
    records[i] = bossDetailRecord(record, { description, pageText }, checkedAt);
    coverage.detailsRun++;
    if (records[i].verification === 'full_jd') cache[record.url] = { listHash: record.contentHash, detail: records[i] };
    fs.writeFileSync(cacheFile, JSON.stringify(cache, null, 2), { mode: 0o600 });
    await checkpoint(records);
  }
  await checkpoint(records);
  finalState = 'ok'; finalMessage = `本机只读采集 ${coverage.queriesRun} 组查询、${coverage.pagesRun} 页、${coverage.detailsRun} 详情；保留 ${records.length} 条，不代表全站覆盖。`;
  console.log(finalMessage);
}
async function checkpoint(records) {
  const snapshot = { sourceID: 'boss', jobs: records.slice(0, 100), coverage };
  fs.writeFileSync(path.join(dataDir, 'boss-last-import.json'), JSON.stringify(snapshot, null, 2) + '\n', { mode: 0o600 });
  partialSaved = true;
  if (!args.includes('--output-only')) await post('/v1/career/import', snapshot);
}
try {
  if (sourceID !== 'boss') throw new Error('此本机浏览器采集器当前支持 --source boss；实习僧使用官方商户 API 或公开详情适配器。');
  if (!args.includes('--login') && !args.includes('--collect')) throw new Error('指定 --login 手动授权，或 --collect 只读采集。');
  if (args.includes('--collect') && !fs.existsSync(profile)) throw new CollectorError('login_required', '没有本机登录会话，请先运行 --login；手机登录无法代替。');
  let chromium;
  try { ({ chromium } = await import('playwright')); } catch { throw new Error('未安装可选 Playwright。请按 docs/career-service.md 安装官方依赖；没有自动下载或运行第三方采集项目。'); }
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 }); fs.writeFileSync(path.join(dataDir, '.gitignore'), '*\n');
  context = await chromium.launchPersistentContext(profile, { headless: args.includes('--scheduled'), viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' });
  context.setDefaultTimeout(8000);
  const page = context.pages()[0] || await context.newPage();
  if (args.includes('--login')) {
    await page.goto('https://www.zhipin.com/', { waitUntil: 'domcontentloaded', timeout: 25000 });
    console.log('请在打开的浏览器中自行扫码登录。不要在终端输入密码。登录成功后返回终端按回车保存本机会话。');
    const input = readline.createInterface({ input: process.stdin, output: process.stdout });
    await input.question('完成本机登录后按回车：'); input.close();
    await pageState(page);
    console.log('浏览器会话已保存在自己的私有数据目录；实际采集时仍会检查登录和安全验证状态。');
  }
  if (args.includes('--collect')) await collect(page);
} catch (error) {
  const state = error.state || 'error';
  finalState = state; finalMessage = error.message;
  console.error(error.message);
  if (token && args.includes('--collect') && !args.includes('--output-only')) await post('/v1/career/collector-status', { sourceID: 'boss', state, message: error.message }).catch(() => {});
  process.exitCode = 1;
} finally {
  if (args.includes('--collect') && fs.existsSync(dataDir)) fs.writeFileSync(path.join(dataDir, 'boss-last-state.json'), JSON.stringify({ state: finalState, message: finalMessage, coverage, partialSaved, finishedAt: new Date().toISOString() }, null, 2) + '\n', { mode: 0o600 });
  if (context) await context.close();
}
