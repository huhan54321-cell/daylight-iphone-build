'use strict';
const { plain, decodeEntities, parseShixiPublic, SourceError, tagsFrom } = require('./career-adapters.cjs');
const { safeURL, source } = require('./career-core.cjs');
// Text hidden by a site's font mapping remains unknown; do not guess digits or letters.
const readable = value => plain(value).replace(/[\uE000-\uF8FF]/g, '□').trim();
function parseShixiSearch(html) {
  if (/访问验证|安全验证|滑动.{0,8}验证|异常访问/.test(plain(html))) throw new SourceError('blocked', '实习僧要求验证，请在电脑处理后恢复');
  const jobs = [];
  for (const block of html.split(/(?=<div\b[^>]*data-intern-id=["']inn_)/i).filter(value => /^<div\b[^>]*data-intern-id=["']inn_/i.test(value)).slice(0, 40)) {
    const id = /data-intern-id=["'](inn_[a-z0-9]+)["']/i.exec(block)?.[1];
    const anchor = /<a\b[^>]*href=["'](https:\/\/www\.shixiseng\.com\/intern\/inn_[^"']+)["'][^>]*>([\s\S]*?)<\/a>/i.exec(block);
    const companyBlock = block.slice(block.indexOf('intern-detail__company'));
    const company = readable(/<a[^>]*>([\s\S]*?)<\/a>/i.exec(companyBlock)?.[1] || '');
    const city = readable(/<span[^>]*class=["'][^"']*\bcity\b[^"']*["'][^>]*>([\s\S]*?)<\/span>/i.exec(block)?.[1] || '');
    if (!id || !anchor || !company || !city) continue;
    jobs.push({ title: readable(anchor[2]), company, city, jobType: '实习', salary: '未注明',
      url: `https://www.shixiseng.com/intern/${id}`, description: '', requirements: [], tags: tagsFrom(readable(anchor[2])),
      publishedAt: null, status: 'unconfirmed', verification: 'listing_only', sourceNote: '公开搜索卡片；□ 表示网页字体信息未识别，薪资及数字条件不推测。' });
  }
  if (!jobs.length && !/暂无.{0,8}(职位|结果)|没有.{0,8}(职位|结果)/.test(plain(html))) throw new SourceError('error', '实习僧搜索结构变化或结果不可读，不能视为没有岗位');
  return jobs;
}
async function collectShixiSearch(request, env, checkedAt) {
  const queries = (env.CAREER_QUERIES || [{ keyword: '具身智能', city: '杭州' }]).slice(0, 3);
  const records = new Map(); let queriesRun = 0, detailsRun = 0, failure = null;
  for (const query of queries) {
    try {
      const url = new URL('https://www.shixiseng.com/interns'); url.searchParams.set('keyword', query.keyword); url.searchParams.set('city', query.city);
      const html = await request(url.href, {}, source('shixiseng-public').hosts);
      for (const job of parseShixiSearch(html)) records.set(job.url, job);
      queriesRun++;
    } catch (error) { failure = error; break; }
  }
  const candidates = [...records.values()];
  for (const candidate of candidates.slice(0, Math.min(4, Number(env.CAREER_MAX_DETAILS) || 4))) {
    if (failure?.state === 'blocked') break;
    try { records.set(candidate.url, parseShixiPublic(await request(candidate.url, {}, source('shixiseng-public').hosts), candidate.url, checkedAt)); detailsRun++; }
    catch (error) { if (error.state === 'blocked') { failure = error; break; } candidate.sourceNote += ' 详情未读取成功。'; }
  }
  return { state: failure ? failure.state || 'error' : 'ok', jobs: [...records.values()],
    coverage: { mode: 'search', queriesRun, pagesRun: queriesRun, detailsRun, partial: true },
    message: `公开搜索已完成 ${queriesRun}/${queries.length} 组关键词，取得 ${records.size} 条岗位线索、${detailsRun} 条完整详情；仅覆盖本轮页面。${failure ? ' 部分请求未完成：' + failure.message : ''}` };
}
const COMPANIES = [
  { name: '西湖机器人', url: 'https://wlrobo.com/module5' },
  { name: '云深处', url: 'https://www.deeprobotics.cn/robot/index/company.html' },
  { name: '网易', url: 'https://hr.163.com/' },
  { name: '腾讯', url: 'https://careers.tencent.com/' },
  { name: '字节跳动', url: 'https://jobs.bytedance.com/' }
];
function parseOfficialStructured(html, pageURL) {
  const nodes = [];
  const visit = value => { if (Array.isArray(value)) value.forEach(visit); else if (value && typeof value === 'object') { if (value['@type'] === 'JobPosting') nodes.push(value); if (value['@graph']) visit(value['@graph']); } };
  for (const m of html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) { try { visit(JSON.parse(m[1])); } catch {} }
  return nodes.flatMap(node => {
    const city = node.jobLocation?.address?.addressLocality;
    if (!node.title || !node.hiringOrganization?.name || !node.description || !city || !node.url) return [];
    let url; try { url = safeURL(new URL(node.url, pageURL).href, 'official'); } catch { return []; }
    return [{ title: node.title, company: node.hiringOrganization.name, city, url, description: plain(node.description),
      jobType: /实习|intern/i.test(node.title + node.employmentType) ? '实习' : '类型未注明', requirements: [], tags: tagsFrom(node.title + plain(node.description)),
      publishedAt: node.datePosted || null, deadline: node.validThrough || null, status: 'unconfirmed', verification: 'full_jd' }];
  });
}
async function collectCompanies(request, env) {
  const jobs = [], checks = [];
  for (const company of COMPANIES) {
    try {
      const html = await request(company.url, {}, source('official').hosts);
      const rows = parseOfficialStructured(html, company.url); jobs.push(...rows);
      checks.push({ ...company, state: rows.length ? 'ok' : 'unreadable', count: rows.length });
    } catch (error) { checks.push({ ...company, state: error.state || 'error', count: 0 }); }
  }
  return { state: jobs.length ? 'ok' : 'error', jobs, coverage: { mode: 'fixed_pages', pagesRun: checks.length, detailsRun: jobs.length, partial: true, companies: checks.map(c => c.name), companyChecks: checks },
    message: `${checks.filter(c => c.state === 'ok').length}/${checks.length} 个企业入口取得结构化职位；其余入口需要专用适配，不能视为没有招聘。宇树由独立来源检查。` };
}
module.exports = { parseShixiSearch, collectShixiSearch, parseOfficialStructured, collectCompanies, COMPANIES };
