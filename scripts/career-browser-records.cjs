'use strict';
const { text, normalizeJob, mergeJobs, safeURL } = require('./career-core.cjs');
const { tagsFrom, plain } = require('./career-adapters.cjs');
const { applyConstraints } = require('./career-constraints.cjs');
function bossListRecord(row, checkedAt) {
  const company = row.brandName || row.companyName || row.company;
  const title = row.jobName || row.title;
  const city = row.cityName || row.city;
  if (!company || !title || !city) return null;
  let url = row.url;
  if (!url && /^[a-zA-Z0-9_-]{4,128}$/.test(row.encryptJobId || '')) url = `https://www.zhipin.com/job_detail/${row.encryptJobId}.html`;
  if (!url) return null;
  const internship = /实习|intern/i.test(title + ' ' + (row.jobExperience || '') + ' ' + (row.jobType || ''));
  try { return normalizeJob({ company, title, city, location: [city, row.areaDistrict, row.businessDistrict].filter(Boolean).join(' · '), url, salary: row.salaryDesc || row.salary || '未注明',
    jobType: internship ? '实习' : '类型未注明', description: text(row.description || '', 4000), requirements: [], tags: Array.isArray(row.skills) ? row.skills.filter(s => typeof s === 'string') : tagsFrom(title), status: 'unconfirmed', verification: 'listing_only', publishedAt: null }, 'boss', checkedAt); } catch { return null; }
}
function bossResponseRecords(json, checkedAt) {
  const list = json?.zpData?.jobList;
  if (!Array.isArray(list)) return [];
  return mergeJobs([], list.slice(0, 100).map(r => bossListRecord(r, checkedAt)).filter(Boolean));
}
function bossDetailRecord(previous, content, checkedAt) {
  if (!previous || !content || !content.description) return previous;
  const description = plain(content.description);
  if (description.length < 80) return previous;
  const closed = /职位已关闭|职位已下线|停止招聘|该职位已结束/.test(content.pageText || '');
  const raw = { ...previous, description, verification: 'full_jd', status: closed ? 'closed' : 'unconfirmed', tags: [...new Set([...previous.tags, ...tagsFrom(description)])] };
  return normalizeJob(applyConstraints(raw, description), 'boss', checkedAt);
}
function bossDocumentIssue(value, body, allowLogin = false) {
  let url;
  try { url = new URL(value); } catch {}
  if (!url || url.protocol !== 'https:' || !['www.zhipin.com', 'zhipin.com'].includes(url.hostname)) {
    return { state: 'blocked', message: 'BOSS 页面退回空白页或离开官网；当前浏览器采集无法使用，未保存为已登录。请在普通浏览器核查，已有岗位保留。' };
  }
  if (/verify|security-check|\/web\/passport\/zp\/security\.html/.test(url.pathname) || /访问验证|安全验证|完成验证后|滑动.*验证|异常访问|验证您的身份/.test(body)) {
    return { state: 'blocked', message: 'BOSS 要求安全验证；采集已停止，请在自己的浏览器处理后重试。' };
  }
  if (!String(body || '').trim()) return { state: 'error', message: 'BOSS 页面没有加载出内容；未将空白页当作登录或采集成功。' };
  if (!allowLogin && (/\/web\/user\//.test(url.pathname) || /扫码登录后.*查看|请登录后.*查看|登录后查看职位/.test(body))) {
    return { state: 'login_required', message: 'BOSS 会话尚未登录或已过期，请运行 --login。' };
  }
  return null;
}
function validServiceURL(value) {
  const url = new URL(value);
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname) || /^(10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$/.test(url.hostname);
  if (url.username || url.password || (url.protocol !== 'https:' && !(url.protocol === 'http:' && local))) throw new Error('服务地址必须为自己的本机/局域网 HTTP 地址，或 HTTPS 地址');
  url.pathname = '/'; url.search = ''; url.hash = '';
  return url;
}
module.exports = { bossListRecord, bossResponseRecords, bossDetailRecord, bossDocumentIssue, validServiceURL };
