'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { source, safeURL, text, normalizeJob } = require('./career-core.cjs');
const { SourceError, parseShixiPublic, parseZhaopin, plain } = require('./career-adapters.cjs');
const { applyConstraints } = require('./career-constraints.cjs');
function detailSource(value) {
  let url; try { url = new URL(value); } catch { return null; }
  if (['www.shixiseng.com','shixiseng.com'].includes(url.hostname) && /^\/intern\/inn_[a-z0-9]+$/i.test(url.pathname)) return 'shixiseng-public';
  if (['www.zhaopin.com','zhaopin.com','jobs.zhaopin.com'].includes(url.hostname) && /\/jobdetail\/|\/CC\w+/i.test(url.pathname)) return 'zhaopin';
  if (['www.zhipin.com','m.zhipin.com','zhipin.com'].includes(url.hostname) && /^\/job_detail\/[a-z0-9_-]+\.html$/i.test(url.pathname)) return 'boss';
  if (['www.unitree.com','unitree.com'].includes(url.hostname) && /^\/cn\/position\/\d+\/?$/.test(url.pathname)) return 'unitree';
  if (['www.career.zju.edu.cn','career.zju.edu.cn'].includes(url.hostname) && url.searchParams.has('zpxxbh')) return 'zju';
  if (['www.nowcoder.com','nowcoder.com'].includes(url.hostname) && /^\/jobs\/detail\/\d+/.test(url.pathname)) return 'nowcoder';
  return null;
}
function loadQueue(dataDir) {
  const file = path.join(dataDir, 'detail-queue.json');
  if (!fs.existsSync(file)) return [];
  const rows = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!Array.isArray(rows)) throw new Error('详情队列格式无效');
  return rows.slice(0, 300).filter(row => detailSource(row.url) === row.sourceID).map(row => ({ ...row, url: safeURL(row.url, row.sourceID) }));
}
function saveQueue(dataDir, rows) { const file = path.join(dataDir, 'detail-queue.json'); fs.writeFileSync(file + '.tmp', JSON.stringify(rows, null, 2) + '\n', { mode: 0o600 }); fs.renameSync(file + '.tmp', file); }
function addDiscoveries(rows, jobs, now) {
  for (const job of jobs) {
    const sourceID = detailSource(job.url);
    if (!sourceID) continue;
    const url = safeURL(job.url, sourceID);
    const prior = rows.find(row => row.url === url);
    if (prior) { prior.lastSeenAt = now; continue; }
    if (rows.length < 300) rows.push({ sourceID, url, state: 'pending', firstSeenAt: now, lastSeenAt: now, lastAttemptAt: null, lastSuccessAt: null, nextAttemptAt: now, attempts: 0, message: '等待核查来源正文' });
  }
  return rows;
}
function parseStructuredDetail(html, sourceID, url, now) {
  if (/安全验证|访问验证|\/web\/passport\/zp\/security\.html/.test(html)) throw new SourceError('blocked', '详情来源要求安全验证，未补全正文');
  const blocks = [...html.matchAll(/<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)].map(match => { try { return JSON.parse(match[1]); } catch { return null; } });
  const data = blocks.flat().find(row => row?.['@type'] === 'JobPosting');
  if (!data?.title || !data?.hiringOrganization?.name || !data?.description || !data?.jobLocation?.address?.addressLocality) throw new SourceError('login_required', '详情未提供已支持的公开职位字段；保留搜索线索，不生成或补猜 JD');
  const requirements = data.qualifications ? plain(data.qualifications).split('\n').filter(Boolean) : [];
  return applyConstraints({ title: data.title, company: data.hiringOrganization.name, city: data.jobLocation.address.addressLocality, location: data.jobLocation.address.streetAddress, jobType: /实习|intern/i.test(data.title + data.employmentType) ? '实习' : '类型未注明', salary: '未注明', url, description: plain(data.description), requirements, publishedAt: data.datePosted, deadline: data.validThrough, checkedAt: now, verification: 'full_jd', status: 'unconfirmed', sourceNote: '公开搜索发现后，已读取来源页面的结构化职位正文；招聘资格仍需核实。' }, plain(data.description) + '\n' + requirements.join('\n'));
}
async function processQueue(rows, request, now, maximum = 2, options = {}) {
  const jobs = [], attempted = [];
  const disabled = new Set(options.disabledSources || []);
  const due = rows.filter(row => !disabled.has(row.sourceID) && Date.parse(row.nextAttemptAt || 0) <= Date.parse(now)).sort((a, b) => String(a.lastAttemptAt || '').localeCompare(String(b.lastAttemptAt || '')) || a.firstSeenAt.localeCompare(b.firstSeenAt)).slice(0, Math.max(0, Math.min(4, maximum)));
  for (const item of due) {
    item.lastAttemptAt = now; item.attempts = Math.min(50, item.attempts + 1); attempted.push(item.url);
    try {
      const html = await request(safeURL(item.url, item.sourceID), {}, source(item.sourceID).hosts);
      const raw = item.sourceID === 'shixiseng-public' ? parseShixiPublic(html, item.url, now) : item.sourceID === 'zhaopin' ? parseZhaopin(html, item.url, now) : parseStructuredDetail(html, item.sourceID, item.url, now);
      jobs.push(normalizeJob({ ...raw, sourceNote: raw.sourceNote || '公开搜索发现后已核查此页面正文；不等同于全站覆盖。' }, item.sourceID, now));
      item.state = 'done'; item.lastSuccessAt = now; item.nextAttemptAt = new Date(Date.parse(now) + 7 * 86400000).toISOString(); item.message = '已核查支持字段，7天后再次核查';
    } catch (error) {
      item.state = error.state === 'blocked' ? 'blocked' : error.state === 'login_required' ? 'unreadable' : 'error';
      item.message = text(error.message, 200); item.nextAttemptAt = new Date(Date.parse(now) + (item.state === 'error' ? Math.min(24, 2 ** Math.min(item.attempts, 5)) : 24) * 3600000).toISOString();
    }
  }
  return { jobs, attempted, pending: rows.filter(row => row.state === 'pending' || row.state === 'error').length, unreadable: rows.filter(row => row.state === 'unreadable' || row.state === 'blocked').length };
}
module.exports = { detailSource, loadQueue, saveQueue, addDiscoveries, parseStructuredDetail, processQueue };
