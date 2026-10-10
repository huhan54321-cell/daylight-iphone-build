'use strict';
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const SOURCES = Object.freeze([
  { id: 'official', name: '企业官方招聘', hosts: ['talent.alibaba.com','careers.tencent.com','hr.163.com','career.huawei.com','jobs.bytedance.com','talent.baidu.com','hr.xiaomi.com','zhaopin.meituan.com','we.dji.com','job.hikrobotics.com','join.hikvision.com','www.unitree.com','unitree.com','www.deeprobotics.cn','www.wlrobo.com','wlrobo.com','www.linx-robot.com','www.westlakedi.com'] },
  { id: 'unitree', name: '宇树官方招聘', hosts: ['www.unitree.com', 'unitree.com'] },
  { id: 'zju', name: '浙大官方招聘', hosts: ['www.career.zju.edu.cn', 'career.zju.edu.cn'] },
  { id: 'shixiseng', name: '实习僧', hosts: ['www.shixiseng.com', 'shixiseng.com', 'open.shixiseng.com'] },
  { id: 'shixiseng-public', name: '实习僧公开详情', hosts: ['www.shixiseng.com', 'shixiseng.com'] },
  { id: 'boss', name: 'BOSS 直聘', hosts: ['www.zhipin.com', 'zhipin.com', 'm.zhipin.com'] },
  { id: 'zhaopin', name: '智联招聘', hosts: ['www.zhaopin.com', 'zhaopin.com', 'jobs.zhaopin.com'] },
  { id: 'nowcoder', name: '牛客招聘', hosts: ['www.nowcoder.com', 'nowcoder.com'] },
  { id: 'tavily', name: '多源公开搜索', hosts: ['www.zhipin.com', 'zhipin.com', 'm.zhipin.com', 'www.shixiseng.com', 'shixiseng.com', 'www.unitree.com', 'unitree.com', 'www.career.zju.edu.cn', 'career.zju.edu.cn', 'www.zhaopin.com', 'zhaopin.com', 'jobs.zhaopin.com', 'www.nowcoder.com', 'nowcoder.com', 'wlrobo.com', 'www.wlrobo.com', 'www.linx-robot.com', 'www.deeprobotics.cn', 'job.hikrobotics.com', 'hr.163.com', 'www.westlakedi.com'] }
]);
const STATES = new Set(['ok', 'login_required', 'blocked', 'not_configured', 'error']);
const STATUSES = new Set(['unconfirmed', 'historical', 'verified', 'closed']);
function source(id) { return SOURCES.find(s => s.id === id); }
function text(value, limit = 1000) {
  return String(value ?? '').replace(/\u0000/g, '').normalize('NFKC').trim().slice(0, limit);
}
function safeURL(value, sourceID) {
  const provider = source(sourceID);
  let parsed;
  try { parsed = new URL(String(value)); } catch { throw new Error('岗位网址无效'); }
  if (!provider || parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.port || !provider.hosts.includes(parsed.hostname)) throw new Error('岗位网址必须来自该来源允许的 HTTPS 域名');
  if (parsed.hash && !/^#(?:\/|!\/)/.test(parsed.hash)) parsed.hash = '';
  if (parsed.hostname === 'm.zhipin.com') parsed.hostname = 'www.zhipin.com';
  for (const key of [...parsed.searchParams.keys()]) if (/^(utm_|spm$|trackingid$)/i.test(key) || (/^(?:www\.)?zhipin\.com$/.test(parsed.hostname) && /^\/job_detail\//.test(parsed.pathname) && /^securityid$/i.test(key))) parsed.searchParams.delete(key);
  return parsed.href;
}
function safeRelatedURL(value) {
  for (const provider of SOURCES) { try { return safeURL(value, provider.id); } catch {} }
  throw new Error('关联网址不属于已注册来源');
}
function dateISO(value) {
  if (value == null || value === '') return null;
  const clean = text(value, 60);
  const civil = /^(\d{4})-(\d{2})-(\d{2})/.exec(clean);
  if (civil) { const y = Number(civil[1]), m = Number(civil[2]), d = Number(civil[3]); const probe = new Date(Date.UTC(y, m - 1, d)); if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) return null; }
  // Source dates without a zone are civil time in China, never the host's local timezone.
  const china = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2})?)$/.exec(clean);
  const date = new Date(china ? `${china[1]}T${china[2].length === 5 ? china[2] + ':00' : china[2]}+08:00` : /^\d{4}-\d{2}-\d{2}$/.test(clean) ? `${clean}T00:00:00+08:00` : clean);
  if (!Number.isFinite(date.getTime())) return null;
  return date.toISOString();
}
function smallInt(value, max) { const n = Number(value); return value != null && value !== '' && Number.isInteger(n) && n > 0 && n <= max ? n : null; }
function deadlineISO(value) { return dateISO(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value) ? value + 'T23:59:59+08:00' : value); }
function normalizeJob(raw, sourceID, checkedAt = new Date().toISOString()) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('岗位应为对象');
  const provider = source(sourceID);
  if (!provider) throw new Error('未知来源');
  const company = text(raw.company, 160), title = text(raw.title, 180), city = text(raw.city, 80);
  if (!company || !title || !city) throw new Error('岗位缺少公司、标题或城市');
  const checked = dateISO(checkedAt);
  if (!checked) throw new Error('核查时间无效');
  const publishedAt = dateISO(raw.publishedAt);
  const deadline = deadlineISO(raw.deadline);
  let status = STATUSES.has(raw.status) ? raw.status : 'unconfirmed';
  if (deadline && Date.parse(deadline) < Date.parse(checked)) status = 'closed';
  const refreshedAt = dateISO(raw.refreshedAt);
  const result = {
    id: '', sourceID, sourceName: provider.name, company, title, city,
    jobType: text(raw.jobType || '类型未注明', 60), salary: text(raw.salary || '未注明', 100),
    location: text(raw.location || city, 180), url: safeURL(raw.url, sourceID),
    description: text(raw.description, 4000),
    requirements: Array.isArray(raw.requirements) ? raw.requirements.slice(0, 24).map(v => text(v, 500)).filter(Boolean) : [],
    tags: Array.isArray(raw.tags) ? [...new Set(raw.tags.slice(0, 20).map(v => text(v, 80)).filter(Boolean))] : [],
    publishedAt, checkedAt: checked, status,
    verification: ['full_jd', 'listing_only', 'unreadable'].includes(raw.verification) ? raw.verification : 'unreadable', refreshedAt, deadline,
    minDays: smallInt(raw.minDays, 7), minMonths: smallInt(raw.minMonths, 24),
    graduateYears: Array.isArray(raw.graduateYears) ? [...new Set(raw.graduateYears.filter(n => Number.isInteger(n) && n >= 2020 && n <= 2040))].slice(0, 12) : [],
    requiredDegree: ['bachelor','master','phd'].includes(raw.requiredDegree) ? raw.requiredDegree : null,
    relatedURLs: Array.isArray(raw.relatedURLs) ? [...new Set(raw.relatedURLs.slice(0, 20).map(safeRelatedURL))] : []
  };
  result.companyIntro = text(raw.companyIntro, 2000);
  result.sourceNote = text(raw.sourceNote, 2000);
  result.sourceJobID = sourceIdentity(sourceID, result.url) || text(raw.sourceJobID || (result.url + '|' + jobKey(result)), 800);
  result.sourceMembers = Array.isArray(raw.sourceMembers) ? raw.sourceMembers.slice(0, 12).map(member => ({ sourceID: member.sourceID, sourceJobID: sourceIdentity(member.sourceID, member.url) || text(member.sourceJobID, 500), url: safeURL(member.url, member.sourceID) })) : [{ sourceID, sourceJobID: result.sourceJobID, url: result.url }];
  result.contentHash = contentHash(result);
  result.id = stableID(result);
  return result;
}
function companyKey(value) {
  let key = text(value, 160).toLowerCase().replace(/\s|[()（）·]/g, '').replace(/(股份有限公司|有限责任公司|有限公司|集团)$/g, '');
  if (/^(杭州)?(群核|酷家乐)/.test(key)) return '群核';
  if (/^(杭州)?宇树/.test(key)) return '宇树';
  if (/^(杭州)?云深处/.test(key)) return '云深处';
  return key;
}
function jobKey(job) {
  const title = text(job.title).toLowerCase().replace(/[\s()（）]/g, '').replace(/j\d{4,8}/gi, '').replace(/热招|急招/g, '');
  const city = text(job.city).replace(/浙江省|市$/g, '');
  // Internship and permanent opportunities must remain distinct, even with the same title.
  const kind = /实习|intern/i.test(job.jobType + job.title) ? 'intern' : /全职|社招|正式/.test(job.jobType) ? 'fulltime' : 'unknown';
  return [companyKey(job.company), title, city, kind].join('|');
}
function strongKey(job) { return job.sourceID + '|' + (job.sourceJobID || job.url); }
function sourceIdentity(sourceID, value) {
  const url = new URL(value);
  if (sourceID === 'boss') return /^\/job_detail\/([a-z0-9_-]+)\.html$/i.exec(url.pathname)?.[1] || null;
  if (sourceID === 'shixiseng' || sourceID === 'shixiseng-public') return /^\/intern\/(inn_[a-z0-9]+)$/i.exec(url.pathname)?.[1] || null;
  if (sourceID === 'unitree') return /^\/cn\/position\/(\d+)\/?$/.exec(url.pathname)?.[1] || null;
  if (sourceID === 'zju') return url.searchParams.get('zpxxbh') || null;
  if (sourceID === 'nowcoder') return /^\/jobs\/detail\/(\d+)\/?$/.exec(url.pathname)?.[1] || null;
  if (sourceID === 'zhaopin') return /^\/jobdetail\/([^/]+?)(?:\.htm[l]?)?\/?$/i.exec(url.pathname)?.[1] || /^\/(CC[a-z0-9_-]+)\.htm[l]?$/i.exec(url.pathname)?.[1] || null;
  return null;
}
function exactPostingURL(value) { return SOURCES.some(provider => { try { return provider.hosts.includes(new URL(value).hostname) && Boolean(sourceIdentity(provider.id, value)); } catch { return false; } }); }
function stableID(job) { return 'job_' + crypto.createHash('sha256').update(strongKey(job)).digest('hex').slice(0, 24); }
function contentHash(job) {
  return crypto.createHash('sha256').update(JSON.stringify([job.company, job.title, job.city, job.jobType, job.salary, job.location, job.description, job.requirements, job.minDays, job.minMonths, job.graduateYears, job.requiredDegree, job.deadline, job.status, job.verification])).digest('hex');
}
function crossSourceCompatible(a, b) {
  if (a.sourceID === b.sourceID || jobKey(a) !== jobKey(b) || a.verification !== 'full_jd' || b.verification !== 'full_jd') return false;
  if ((a.sourceMembers || [a]).some(member => member.sourceID === b.sourceID)) return false;
  if (a.minDays !== b.minDays || a.minMonths !== b.minMonths || a.requiredDegree !== b.requiredDegree || JSON.stringify(a.graduateYears) !== JSON.stringify(b.graduateYears) || a.location !== b.location) return false;
  const normalize = s => text(s, 4000).toLowerCase().replace(/\s|[，。,.;；:：!！?？]/g, '');
  if (!a.requirements.length || !b.requirements.length || JSON.stringify(a.requirements.map(normalize).sort()) !== JSON.stringify(b.requirements.map(normalize).sort())) return false;
  const left = normalize(a.description), right = normalize(b.description);
  if (left.length < 40 || right.length < 40) return false;
  if (left === right) return true;
  const grams = str => new Set(Array.from({ length: str.length - 1 }, (_, i) => str.slice(i, i + 2)));
  const x = grams(left), y = grams(right); let common = 0;
  for (const gram of x) if (y.has(gram)) common++;
  return common / (x.size + y.size - common) >= 0.75;
}
function mergeJobs(existing, incoming) {
  const records = [], index = new Map();
  for (const job of [...existing, ...incoming]) {
    const key = strongKey(job);
    let position = index.get(key);
    if (position === undefined) {
      const found = records.findIndex(previous => ((previous.url === job.url || previous.sourceMembers?.some(member => member.url === job.url)) && (exactPostingURL(job.url) || jobKey(previous) === jobKey(job))) || crossSourceCompatible(previous, job));
      if (found >= 0) position = found;
    }
    const previous = position === undefined ? null : records[position];
    if (!previous) {
      const members = job.sourceMembers || [{ sourceID: job.sourceID, sourceJobID: job.sourceJobID || job.url, url: job.url }];
      for (const member of members) index.set(strongKey(member), records.length);
      index.set(key, records.length); records.push({ ...job, sourceMembers: members, id: job.id || stableID(job), relatedURLs: [...new Set(job.relatedURLs || [])] }); continue;
    }
    const timeDelta = Date.parse(job.checkedAt) - Date.parse(previous.checkedAt);
    const trust = id => id === 'tavily' ? 0 : id === 'zju' ? 1 : 2;
    const winner = timeDelta > 0 || (timeDelta === 0 && trust(job.sourceID) > trust(previous.sourceID)) ? job : previous;
    const loser = winner === job ? previous : job;
    // A search excerpt is not evidence that a closed posting reopened.
    const keepFull = previous.verification === 'full_jd' && job.verification !== 'full_jd';
    const keepClosed = previous.status === 'closed' && (job.sourceID === 'tavily' || job.verification !== 'full_jd');
    const selected = keepFull || keepClosed ? previous : winner;
    const merged = { ...selected, id: previous.id || stableID(selected), relatedURLs: [...new Set([...(previous.relatedURLs || []), ...(job.relatedURLs || []), previous.url, job.url])].filter(url => url !== selected.url).slice(0, 20),
      description: selected.description || loser.description, requirements: selected.requirements.length ? selected.requirements : loser.requirements };
    merged.sourceMembers = [...(previous.sourceMembers || [previous]), ...(job.sourceMembers || [job])].filter((member, i, all) => all.findIndex(candidate => strongKey(candidate) === strongKey(member)) === i).map(member => ({ sourceID: member.sourceID, sourceJobID: member.sourceJobID || member.url, url: member.url }));
    merged.contentHash = contentHash(merged);
    records[position] = merged; index.set(key, position); for (const member of merged.sourceMembers) index.set(strongKey(member), position);
  }
  return records.sort((a, b) => a.id.localeCompare(b.id)).slice(0, 1500);
}
function initialFeed(now = new Date().toISOString()) {
  return { schemaVersion: 1, generatedAt: now, jobs: [], sources: SOURCES.map(s => ({ id: s.id, name: s.name, state: s.id === 'boss' ? 'login_required' : 'not_configured', lastAttemptAt: null, lastSuccessAt: null, count: 0, message: s.id === 'boss' ? '需在本机授权登录后导入岗位；手机登录不等于本机采集会话。' : '尚未刷新或配置。' })), articles: [] };
}
function readFeed(dataDir) {
  const file = path.join(dataDir, 'feed.json');
  if (!fs.existsSync(file)) return initialFeed();
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (saved.schemaVersion !== 1 || !Array.isArray(saved.jobs) || !Array.isArray(saved.sources)) throw new Error('岗位缓存格式无效，保留文件等待人工修复');
  saved.jobs = mergeJobs([], saved.jobs.map(row => ({ ...normalizeJob(row, row.sourceID, row.checkedAt), id: row.id })));
  return saved;
}
function writeFeed(dataDir, feed) {
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const file = path.join(dataDir, 'feed.json'), temp = file + '.tmp';
  fs.writeFileSync(temp, JSON.stringify(feed, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(temp, file);
}
function publicFeed(feed, now = new Date().toISOString()) {
  return { ...feed, jobs: feed.jobs.map(job => job.deadline && Date.parse(job.deadline) < Date.parse(now) ? { ...job, status: 'closed' } : job.status === 'verified' && Date.parse(now) - Date.parse(job.checkedAt) > 7 * 86400000 ? { ...job, status: 'unconfirmed' } : job) };
}
function applySourceResult(feed, sourceID, result, now) {
  const previous = feed.sources.find(s => s.id === sourceID);
  if (!previous || !STATES.has(result.state)) throw new Error('来源结果无效');
  if (result.state === 'ok' || (Array.isArray(result.jobs) && result.jobs.length)) {
    const current = result.jobs.map(j => normalizeJob(j, sourceID, j.checkedAt || now));
    // A bounded scan is partial. Missing from a page is not evidence of closure or failure.
    feed.jobs = mergeJobs(feed.jobs, current);
  }
  feed.sources = feed.sources.map(s => s.id !== sourceID ? s : ({ ...s, state: result.state, lastAttemptAt: now, lastSuccessAt: result.state === 'ok' ? now : s.lastSuccessAt, count: result.state === 'ok' ? result.jobs.length : result.jobs?.length ? feed.jobs.filter(j => j.sourceID === sourceID).length : s.count, message: text(result.message, 300), ...(result.coverage ? { coverage: result.coverage } : {}) }));
  feed.generatedAt = now;
  return feed;
}
function researchToJob(raw, checkedAt) {
  const labels = { 'BOSS直聘': 'boss', 'BOSS 直聘': 'boss', '实习僧': 'shixiseng-public', '浙江大学就业服务平台': 'zju', '浙大就业网': 'zju', '宇树官网': 'unitree', '宇树官方招聘': 'unitree' };
  const sourceID = raw.sourceID || labels[raw.source] || (String(raw.sourceUrl).includes('zhipin.com') ? 'boss' : String(raw.sourceUrl).includes('shixiseng.com') ? 'shixiseng-public' : String(raw.sourceUrl).includes('zhaopin.com') ? 'zhaopin' : String(raw.sourceUrl).includes('nowcoder.com') ? 'nowcoder' : String(raw.sourceUrl).includes('unitree.com') ? 'unitree' : String(raw.sourceUrl).includes('zju.edu.cn') ? 'zju' : 'tavily');
  return normalizeJob({ ...raw, jobType: raw.employmentType || raw.jobType, url: raw.sourceUrl || raw.url, description: (raw.responsibilities || []).join('\n'), requirements: raw.requirements || [], tags: [raw.category].filter(Boolean), publishedAt: raw.publishedAt, refreshedAt: raw.refreshedAt,
    status: raw.status === 'closed' || raw.status === 'expired' ? 'closed' : raw.status === 'historical' ? 'historical' : 'unconfirmed', minDays: raw.constraints?.daysPerWeek, minMonths: raw.constraints?.months,
    graduateYears: Array.isArray(raw.constraints?.graduationYear) ? raw.constraints.graduationYear : Number.isInteger(raw.constraints?.graduationYear) ? [raw.constraints.graduationYear] : [], relatedURLs: raw.listingUrl ? [raw.listingUrl] : [] }, sourceID, raw.lastCheckedAt || raw.observedAt || checkedAt);
}
module.exports = { SOURCES, source, text, safeURL, safeRelatedURL, dateISO, deadlineISO, sourceIdentity, exactPostingURL, normalizeJob, jobKey, strongKey, stableID, contentHash, crossSourceCompatible, mergeJobs, initialFeed, readFeed, writeFeed, publicFeed, applySourceResult, researchToJob };
