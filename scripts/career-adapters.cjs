'use strict';
const crypto = require('node:crypto');
const { text, safeURL, dateISO, deadlineISO, source, exactPostingURL } = require('./career-core.cjs');
const { applyConstraints } = require('./career-constraints.cjs');
const UNITREE_URL = 'https://www.unitree.com/cn/position/';
const ZJU_URL = 'https://www.career.zju.edu.cn/jyxt/sczp/zphgl/ckZphdwXq.zf?dwxxid=761C0E152EE024AFE055000000000001&zphbh=4A1E5434BDBC2BCEE0653A68DD0E9B18&zphsqbh=c580d07223d2c9238242b3455027755f';
const SHIXI_PUBLIC_URL = 'https://www.shixiseng.com/intern/inn_rp3z5fbft3rh';
const KEYWORDS = ['具身智能', '机器人仿真', '机器人算法'];
class SourceError extends Error {
  constructor(state, message) { super(message); this.state = state; }
}
function decodeEntities(html) {
  return String(html).replace(/&#(x[0-9a-f]+|\d+);?/gi, (_, value) => {
    const n = /^x/i.test(value) ? parseInt(value.slice(1), 16) : Number(value);
    return n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : '';
  }).replace(/&nbsp;|&amp;|&quot;|&apos;|&lt;|&gt;/g, v => ({'&nbsp;':' ', '&amp;':'&', '&quot;':'"', '&apos;':"'", '&lt;':'<', '&gt;':'>'})[v]);
}
function plain(html) {
  return text(decodeEntities(String(html).replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '').replace(/<\/(p|li|div|h[1-6])\s*>|<br\s*\/?\s*>/gi, '\n').replace(/<[^>]+>/g, '')), 200000).replace(/[ \t]+/g, ' ').replace(/\n\s*\n/g, '\n').trim();
}
function fullPlain(html, limit = 200000) { return plain(html).slice(0, limit); }
function matchHTML(html, expression) { const match = expression.exec(html); return match ? match[1] : ''; }
function classHTML(html, className, tagName = 'div') {
  const escaped = className.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const expression = new RegExp(`<${tagName}\\b[^>]*class=["'][^"']*\\b${escaped}\\b[^"']*["'][^>]*>`, 'ig');
  let opening;
  while ((opening = expression.exec(html))) {
    const classes = opening[0].match(/class=["']([^"']*)["']/i)?.[1].split(/\s+/) || [];
    if (!classes.includes(className)) continue;
    const offset = expression.lastIndex, tags = new RegExp(`<\\/?${tagName}\\b[^>]*>`, 'ig');
    tags.lastIndex = offset; let depth = 1, match;
    while ((match = tags.exec(html))) { depth += /^<\//.test(match[0]) ? -1 : /\/>$/.test(match[0]) ? 0 : 1; if (!depth) return html.slice(offset, match.index); }
  }
  return '';
}
function number(value, max) { const n = Number(value); return Number.isInteger(n) && n > 0 && n <= max ? n : null; }
function tagsFrom(value) { return ['具身智能','机器人','仿真','强化学习','模仿学习','C++','Python','PyTorch','ROS','SLAM','嵌入式','数据'].filter(t => value.toLowerCase().includes(t.toLowerCase())); }
function relevant(value) { return /机器人|具身|仿真|强化学习|机械臂|运动控制|嵌入式|C\+\+|AI算法|数据管线|AI\s*Infra/.test(value); }
function sourcePageState(html) {
  // Check page challenge content, not normal navigation's login button.
  if (/访问验证|安全验证|完成验证后|滑动.*验证|异常访问|访问过于频繁|verify\.html|security-check/i.test(html)) throw new SourceError('blocked', '来源要求安全验证；停止采集，保留上次结果。');
}
function parseUnitree(html, checkedAt) {
  sourcePageState(html);
  const jobs = [];
  for (const match of html.matchAll(/<a\b[^>]*href=["'](\/cn\/position\/\d+)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
    const body = match[2];
    const title = plain(matchHTML(body, /<p[^>]*class=["'][^"']*\btitle\b[^"']*["'][^>]*>([\s\S]*?)<\/p>/i).replace(/<span[\s\S]*?<\/span>/gi, ''));
    const base = plain(matchHTML(body, /<p[^>]*class=["'][^"']*base-info[^"']*["'][^>]*>([\s\S]*?)<\/p>/i));
    if (!title || !base || !relevant(title)) continue;
    const location = base.split('|')[0].trim();
    const description = plain(matchHTML(body, /<div[^>]*class=["'][^"']*\bduty\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/i));
    jobs.push({ company: '宇树科技', title, city: location.replace(/市$/, ''), location, jobType: /实习/.test(title) ? '实习' : '类型未注明', salary: '未注明', url: new URL(match[1], UNITREE_URL).href,
      description, requirements: [], tags: tagsFrom(title + description), publishedAt: null, checkedAt, status: 'verified', verification: 'listing_only' });
  }
  if (!jobs.length) throw new SourceError('error', '公开招聘页结构变化或未取得岗位正文，未将其当作零岗位。');
  return jobs.slice(0, 80);
}
function parseZJU(html, checkedAt) {
  sourcePageState(html);
  const company = plain(matchHTML(html, /<h3[^>]*>([\s\S]*?)<\/h3>/i));
  const blocks = html.split(/<div\b[^>]*class=["']post post-list zp-info-list["'][^>]*>/i).slice(1);
  const jobs = [];
  for (const block of blocks) {
    const head = /<h4[^>]*>\s*<a[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i.exec(block);
    if (!head || !company) continue;
    const title = plain(head[2]);
    if (!relevant(title)) continue;
    const info = matchHTML(block, /<p[^>]*class=["']zp-info-left-detail["'][^>]*>([\s\S]*?)<\/p>/i);
    const values = [...info.matchAll(/<span[^>]*>([\s\S]*?)<\/span>/gi)].map(m => plain(m[1]));
    const publishedAt = plain(matchHTML(block, /<p[^>]*class=["']zp-info-right-time["'][^>]*>([\s\S]*?)<\/p>/i));
    const detail = matchHTML(block, /<div[^>]*class=["']post-des["'][^>]*>([\s\S]*?)<\/div>/i);
    const parts = detail.split(/(?:<[^>]+>)*岗位要求[：:]?(?:<[^>]+>)*/);
    const requirements = parts.length > 1 ? plain(parts.slice(1).join(' ')).split('\n').filter(Boolean).slice(0, 24) : [];
    const deadline = /checkGwsq\([^,]+,["'](\d{4}-\d{2}-\d{2})["']\)/.exec(block)?.[1];
    const status = deadline && Date.parse(deadlineISO(deadline)) < Date.parse(checkedAt) ? 'closed' : 'unconfirmed';
    jobs.push({ company, title, city: (values[1] || '').includes('杭州') ? '杭州' : (values[1] || '城市未注明'), location: values[1], jobType: values[2] || '类型未注明', salary: values[0], url: new URL(decodeEntities(head[1]), ZJU_URL).href,
      description: plain(parts[0]).replace(/^职位描述\s*/, ''), requirements, publishedAt, checkedAt, deadline, status, verification: 'full_jd', tags: tagsFrom(title + plain(detail)), minMonths: /6个月以上/.test(plain(detail)) ? 6 : null });
  }
  if (!jobs.length) throw new SourceError('error', '浙大页面未取得可解析岗位，保留上次结果。');
  return jobs.slice(0, 60);
}
function parseShixiPublic(html, url, checkedAt) {
  sourcePageState(html);
  const content = fullPlain(html);
  const metadata = plain(classHTML(html, 'job_msg'));
  const json = [...html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)].map(m => { try { return JSON.parse(m[1]); } catch { return null; } }).find(j => j && j['@type'] === 'JobPosting');
  const metaTitle = matchHTML(html, /<meta[^>]*property=["']og:title["'][^>]*content=["']([^"']*)/i);
  const documentTitle = plain(matchHTML(html, /<title[^>]*>([\s\S]*?)<\/title>/i));
  const titleParts = documentTitle.match(/^(.+?)实习招聘-(.+?)实习生招聘/);
  const title = text(json?.title || plain(matchHTML(html, /<h[12][^>]*class=["'][^"']*(?:job-name|intern-name|new_job_name|job_name)[^"']*["'][^>]*>([\s\S]*?)<\/h[12]>/i)) || titleParts?.[1] || plain(metaTitle).split('招聘')[0].replace(/-实习僧.*$/, ''));
  const company = text(json?.hiringOrganization?.name || titleParts?.[2] || plain(matchHTML(html, /<(?:a|span|div)[^>]*class=["'][^"']*(?:com-name|company-name|company_name|com_intro|job_com_name)[^"']*["'][^>]*>([\s\S]*?)<\/(?:a|span|div)>/i)));
  const descriptionHTML = json?.description || classHTML(html, 'job_detail') || classHTML(html, 'job-description') || classHTML(html, 'job-detail');
  const city = text(json?.jobLocation?.address?.addressLocality || plain(matchHTML(html, /<span[^>]*class=["'][^"']*\bjob_position\b[^"']*["'][^>]*>([\s\S]*?)<\/span>/i)));
  if (!title || !company || !city || !descriptionHTML) throw new SourceError('login_required', '公开详情未取得完整公司、地点和正文；需授权采集或商户 API，未推测岗位。');
  const requirementsBlock = plain(classHTML(html, 'job_request'));
  const deadline = json?.validThrough || requirementsBlock.match(/(?:截止日期|截止时间)\s*[：:]?\s*(\d{4}-\d{2}-\d{2})/)?.[1];
  const closed = /职位已下线|岗位已下线|职位已过期|该职位已关闭|暂不接受投递/.test(plain(classHTML(html, 'resume_apply'))) || (deadline && Date.parse(deadlineISO(deadline)) < Date.parse(checkedAt));
  const description = plain(descriptionHTML);
  return applyConstraints({ company, title, city, location: json?.jobLocation?.address?.streetAddress || city, jobType: '实习', salary: metadata.match(/\d+\s*[-—~]\s*\d+\s*(?:元)?\s*\/\s*天/)?.[0] || '未注明', url,
    description, requirements: [], tags: tagsFrom(title + description), publishedAt: json?.datePosted || null, deadline, verification: 'full_jd', status: closed ? 'closed' : 'unconfirmed', minDays: number(metadata.match(/(\d)\s*天\s*[/／]\s*周/)?.[1], 7), minMonths: number(metadata.match(/(\d+)\s*个月/)?.[1], 24) }, description);
}
function parseZhaopin(html, url, checkedAt) {
  sourcePageState(html);
  const data = [...html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)].map(m => { try { return JSON.parse(m[1]); } catch { return null; } }).flat().find(j => j && j['@type'] === 'JobPosting');
  if (!data?.title || !data?.hiringOrganization?.name || !data?.description || !data?.jobLocation?.address?.addressLocality) throw new SourceError('login_required', '智联公开详情未取得可核查完整字段，需登录后导入，不推测正文。');
  const deadline = data.validThrough;
  return applyConstraints({ title: data.title, company: data.hiringOrganization.name, city: data.jobLocation.address.addressLocality, location: data.jobLocation.address.streetAddress, jobType: /实习|intern/i.test(data.title + data.employmentType) ? '实习' : '类型未注明', salary: '未注明', url, description: plain(data.description), requirements: [], tags: tagsFrom(data.title + data.description), publishedAt: data.datePosted, deadline, checkedAt, verification: 'full_jd', status: deadline && Date.parse(deadlineISO(deadline)) < Date.parse(checkedAt) ? 'closed' : 'unconfirmed' }, plain(data.description));
}
function shixiSignature(appID, secret, unixSeconds) {
  const stamp = String(unixSeconds);
  return { sign: crypto.createHash('md5').update(appID + secret + stamp).digest('hex').toUpperCase(), authorization: Buffer.from(appID + ':' + stamp).toString('base64') };
}
function shixiRecord(raw, checkedAt, detail = false) {
  const deadline = detail ? raw.endtime : raw.effective_time;
  const closed = String(raw.overdue || '') === '1' || (raw.status && raw.status !== 'normal') || (deadline && Date.parse(deadlineISO(deadline)) < Date.parse(checkedAt));
  const id = raw.uuid || raw.intern_id;
  if (!/^inn_[a-z0-9]+$/i.test(id || '')) throw new SourceError('error', '实习僧返回无效岗位编号');
  const description = plain(raw.info || '');
  return applyConstraints({ company: raw.cname || raw.company_name, title: raw.iname || raw.name, city: raw.city, location: raw.address || raw.city, jobType: '实习', salary: `${raw.minsal || raw.minsalary || '?'}–${raw.maxsal || raw.maxsalary || '?'} 元/天`, url: `https://www.shixiseng.com/intern/${id}`, description, requirements: [], tags: tagsFrom((raw.iname || raw.name || '') + description),
    publishedAt: raw.build_time || null, refreshedAt: raw.refresh || raw.refresh_time || null, deadline, checkedAt, verification: detail && description ? 'full_jd' : 'listing_only', status: closed ? 'closed' : detail && description ? 'verified' : 'unconfirmed', minDays: number(raw.day || raw.dayperweek, 7), minMonths: number(raw.month || raw.month_num, 24) }, description);
}
function boundedFetch(fetchImpl = global.fetch, options = {}) {
  let remaining = options.maxRequests || 32, lastStarted = 0;
  const startedAt = Date.now(), maxElapsed = options.maxElapsed || 90000;
  return async function request(url, settings = {}, allowedHosts) {
    if (remaining <= 0 || Date.now() - startedAt > maxElapsed) throw new SourceError('error', '本次采集达到请求或时间上限，下次刷新继续。');
    const gap = options.delay ?? 300;
    const pause = Math.max(0, gap - (Date.now() - lastStarted));
    if (pause) await new Promise(resolve => setTimeout(resolve, pause));
    lastStarted = Date.now();
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), options.timeout || (new URL(url).hostname === 'api.tavily.com' ? 30000 : 10000));
    try {
      let current = new URL(url), response;
      for (let n = 0; n <= 2; n++) {
        if (remaining <= 0) throw new SourceError('error', '本次来源请求数量达到上限');
        if (current.protocol !== 'https:' || current.username || current.password || current.port || !allowedHosts.includes(current.hostname)) throw new SourceError('error', '采集地址或跳转不属于允许的来源');
        if (options.onRequest) await options.onRequest(current.href);
        remaining--;
        response = await fetchImpl(current.href, { ...settings, redirect: 'manual', signal: controller.signal, headers: { 'User-Agent': 'DaylightPersonalCareer/1.0 (limited personal research)', ...settings.headers } });
        if (![301,302,303,307,308].includes(response.status)) break;
        const next = new URL(response.headers.get('location'), current);
        if (settings.headers?.Authorization && next.origin !== current.origin) throw new SourceError('error', '带认证的来源跳转已停止');
        current = next;
        if (n === 2) throw new SourceError('error', '来源跳转次数超限');
      }
      if ([401,403].includes(response.status)) throw new SourceError(response.status === 401 ? 'login_required' : 'blocked', '来源拒绝访问或需登录，保留已有结果。');
      if (response.status === 429) throw new SourceError('blocked', '来源限流，本次停止采集。');
      if (!response.ok) throw new SourceError('error', `来源 HTTP ${response.status}，保留已有结果。`);
      const max = options.maxBytes || 2 * 1024 * 1024;
      if (Number(response.headers.get('content-length') || 0) > max) throw new SourceError('error', '来源响应过大');
      const chunks = []; let size = 0;
      for await (const chunk of response.body) { size += chunk.length; if (size > max) { controller.abort(); throw new SourceError('error', '来源响应超过大小上限'); } chunks.push(Buffer.from(chunk)); }
      return Buffer.concat(chunks).toString('utf8');
    } catch (error) {
      if (error instanceof SourceError) throw error;
      throw new SourceError('error', controller.signal.aborted ? '来源请求超时，保留已有结果。' : '来源网络连接失败，保留已有结果。');
    } finally { clearTimeout(timer); }
  };
}
async function collectShixiAPI(request, env, checkedAt) {
  if (!env.SHIXISENG_APP_ID || !env.SHIXISENG_APP_SECRET) return { state: 'not_configured', jobs: [], message: '实习僧官方 API 需商务提供 APP_ID/APP_SECRET 并配置 IP 白名单；个人登录不能代替商户授权。' };
  async function call(endpoint, params) {
    const signed = shixiSignature(env.SHIXISENG_APP_ID, env.SHIXISENG_APP_SECRET, Math.floor(Date.now() / 1000));
    const body = new URLSearchParams({ ...params, appid: env.SHIXISENG_APP_ID, sign: signed.sign }).toString();
    const raw = await request(`https://open.shixiseng.com${endpoint}`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8', Accept: 'text/html', Authorization: signed.authorization }, body }, ['open.shixiseng.com']);
    let parsed; try { parsed = JSON.parse(raw); } catch { throw new SourceError('error', '实习僧 API 返回非 JSON，未覆盖缓存'); }
    if (parsed.code !== 100) throw new SourceError([301,303,305,306,309,310,314,317].includes(parsed.code) ? 'blocked' : 'error', `实习僧 API 拒绝请求（代码 ${Number(parsed.code) || 0}）；请检查商户授权、签名与 IP 白名单。`);
    return parsed.msg;
  }
  const queries = Array.isArray(env.CAREER_QUERIES) ? env.CAREER_QUERIES.slice(0, 8) : KEYWORDS.map(keyword => ({ keyword, city: '杭州' }));
  const records = new Map(), pages = Math.max(1, Math.min(3, Number(env.CAREER_PAGES_PER_QUERY) || 1)), queryPages = {};
  let searches = 0, queriesRun = 0, failure = null;
  try {
    for (const { keyword, city, queryID, pageStart = 2 } of queries) {
      const plannedPages = [1, ...Array.from({ length: pages - 1 }, (_, i) => Math.min(100, pageStart + i))];
      for (const page of plannedPages) {
        const rows = await call('/intern/search', { keyword, city, page: String(page), limit: '20' });
        searches++;
        if (!Array.isArray(rows)) throw new SourceError('error', '实习僧搜索响应结构不符');
        for (const row of rows) if (relevant(row.name || '')) records.set(row.uuid || row.intern_id, row);
        if (queryID) queryPages[queryID] = rows.length < 20 ? 2 : page > 1 ? Math.min(100, page + 1) : pageStart;
        if (rows.length < 20) break;
      }
      queriesRun++;
    }
  } catch (error) { failure = error; }
  const values = [...records], jobs = [], detailedIDs = new Set();
  const count = Math.min(values.length, Number.isFinite(Number(env.CAREER_MAX_DETAILS)) ? Math.max(0, Math.min(12, Number(env.CAREER_MAX_DETAILS))) : 12);
  const cursor = Number(env.CAREER_DETAIL_CURSOR) || 0;
  for (let i = 0; i < count; i++) {
    const [id, row] = values[(cursor + i) % values.length];
    if (!/^inn_[a-z0-9]+$/i.test(id || '')) continue;
    if (failure) break;
    try {
      const detail = await call('/intern/info', { uuid: id });
      if (!detail || typeof detail !== 'object' || Array.isArray(detail)) throw new SourceError('error', '实习僧详情响应结构不符');
      jobs.push(shixiRecord({ ...row, ...detail, uuid: id }, checkedAt, true));
      detailedIDs.add(id);
    } catch (error) { failure = error; break; }
  }
  for (const [id, row] of values.slice(0, 100)) if (!detailedIDs.has(id) && /^inn_[a-z0-9]+$/i.test(id || '')) jobs.push(shixiRecord(row, checkedAt));
  return { state: failure ? failure.state || 'error' : 'ok', jobs, coverage: { queriesRun, pagesRun: searches, detailsRun: detailedIDs.size, nextDetailCursor: values.length ? (cursor + detailedIDs.size) % values.length : 0, queryPages, partial: true }, message: failure ? `${failure.message} 本次已保留 ${jobs.length} 条部分结果。` : `官方 API 搜索 ${queriesRun} 组关键词、${searches} 页、${jobs.length} 个去重岗位；核查 ${detailedIDs.size} 详情，未覆盖全站。` };
}
async function collectTavily(request, env) {
  if (!env.TAVILY_API_KEY) return { state: 'not_configured', jobs: [], message: '搜索 API Key 未配置；公司和招聘站检索尚未运行。' };
  const jobs = [];
  let queriesRun = 0, failure = null;
  const queries = Array.isArray(env.CAREER_QUERIES) ? env.CAREER_QUERIES.slice(0, 8) : KEYWORDS.map(keyword => ({ keyword, city: '杭州' }));
  for (const { keyword, city } of queries) {
    let parsed;
    try {
      const raw = await request('https://api.tavily.com/search', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.TAVILY_API_KEY}` }, body: JSON.stringify({ query: `${city} ${keyword} 招聘`, search_depth: 'basic', auto_parameters: false, max_results: 10, include_answer: false, include_raw_content: false, include_domains: source('tavily').hosts, include_domains_mode: 'restrict' }) }, ['api.tavily.com']);
      try { parsed = JSON.parse(raw); } catch { throw new SourceError('error', '搜索服务返回非 JSON'); }
      if (!Array.isArray(parsed.results)) throw new SourceError('error', '搜索结果结构不符');
    } catch (error) {
      failure = error instanceof SourceError ? error : new SourceError('error', '搜索请求未完成，保留成功线索');
      break;
    }
    queriesRun++;
    for (const row of parsed.results.slice(0, 10)) {
      if (!row || typeof row !== 'object') continue;
      const evidence = (row.title || '') + ' ' + (row.content || '');
      if (!/实习|招聘|岗位|职位/.test(evidence) || !relevant(evidence)) continue;
      let url; try { url = safeURL(row.url, 'tavily'); } catch { continue; }
      // A search/category page can mention many unrelated jobs and cities.
      // Keep only recognized posting URLs; generic page titles still need JD verification.
      if (!exactPostingURL(url)) continue;
      // Search snippets are clues; never synthesize employer requirements or an open status.
      const title = text(row.title, 180);
      jobs.push({ company: '公司待核查', title, city: /杭州/.test(title + row.content) ? '杭州' : '城市待核查', jobType: /实习/.test(title) ? '实习' : '类型未注明', salary: '未注明', url, description: text(row.content, 1000), requirements: [], tags: ['搜索线索', ...tagsFrom(title + row.content)], publishedAt: null, verification: 'listing_only', status: 'unconfirmed' });
    }
  }
  return { state: failure ? failure.state : 'ok', jobs, coverage: { queriesRun, pagesRun: queriesRun, detailsRun: 0, partial: true }, message: failure ? `${failure.message} 已完成 ${queriesRun}/${queries.length} 组查询，保留 ${jobs.length} 条具体页面线索；未完成的查询进度不跳过。` : `公开搜索 ${queriesRun} 组关键词，只提供待核查线索，不等同于招聘站全量或当前可投递岗位。` };
}
async function collectSource(sourceID, request, env, checkedAt) {
  const fixedCoverage = (jobs, pagesRun, detailsRun) => ({ mode: 'fixed_pages', cities: [...new Set(jobs.map(j=>j.city))], keywords: [], companies: [...new Set(jobs.map(j=>j.company))], totalQueries: 0, queriesRun: 0, pagesRun, detailsRun });
  if (sourceID === 'unitree') { const jobs = parseUnitree(await request(UNITREE_URL, {}, source('unitree').hosts), checkedAt); return { state: 'ok', jobs, coverage: fixedCoverage(jobs, 1, 0), message: '已读取官方公开岗位列表；未注明的实习类型、薪资、毕业年份保持未知。' }; }
  if (sourceID === 'zju') { const jobs = parseZJU(await request(ZJU_URL, {}, source('zju').hosts), checkedAt); return { state: 'ok', jobs, coverage: fixedCoverage(jobs, 1, 0), message: '已读取浙大招聘来源，保留原发布日期和有效期；页面仍可读不保证仍有名额。' }; }
  if (sourceID === 'shixiseng') return collectShixiAPI(request, env, checkedAt);
  if (sourceID === 'tavily') return collectTavily(request, env);
  if (sourceID === 'boss') return { state: 'login_required', jobs: [], message: '需运行本机 BOSS 授权采集器；手机已登录不会自动提供电脑会话。遇到安全验证停止，已导入岗位保留。' };
  if (sourceID === 'nowcoder') return { state: 'not_configured', jobs: [], message: '已保留牛客公开核查线索；此版未接入牛客自动适配器。' };
  if (sourceID === 'zhaopin') {
    if (!env.ZHAOPIN_PUBLIC_URLS) return { state: 'not_configured', jobs: [], message: '智联公开详情链接尚未配置；已保留人工核查线索，不代表已实现全站采集。' };
    const urls = JSON.parse(env.ZHAOPIN_PUBLIC_URLS).slice(0, 5).map(u => safeURL(u, sourceID));
    const jobs = [];
    for (const url of urls) jobs.push(parseZhaopin(await request(url, {}, source(sourceID).hosts), url, checkedAt));
    return { state: 'ok', jobs, coverage: fixedCoverage(jobs, 0, urls.length), message: '已核查配置的智联公开详情；只覆盖这些链接。' };
  }
  if (sourceID === 'shixiseng-public') {
    const urls = env.SHIXISENG_PUBLIC_URLS ? JSON.parse(env.SHIXISENG_PUBLIC_URLS).slice(0, 5).map(u => safeURL(u, sourceID)) : [SHIXI_PUBLIC_URL];
    const jobs = [];
    for (const url of urls) jobs.push(parseShixiPublic(await request(url, {}, source(sourceID).hosts), url, checkedAt));
    return { state: 'ok', jobs, coverage: fixedCoverage(jobs, 0, urls.length), message: '仅核查配置的公开详情链接，不代表实习僧全站采集。过期和下线职位不作为可投递推荐。' };
  }
  throw new SourceError('error', '未知采集来源');
}
module.exports = { UNITREE_URL, ZJU_URL, SourceError, plain, fullPlain, decodeEntities, tagsFrom, parseUnitree, parseZJU, parseShixiPublic, parseZhaopin, shixiSignature, shixiRecord, boundedFetch, collectShixiAPI, collectTavily, collectSource };
