'use strict';

const crypto = require('node:crypto');
const relevance = require('./xhs-relevance.cjs');
const DAY = 86400000;
const DATE_KINDS = new Set(['exact', 'relative', 'month_day', 'edited', 'unknown']);
const COVERAGE_STATES = new Set(['partial', 'visible_end', 'failed', 'not_opened']);

function clean(value, max = 1000) {
  return String(value ?? '').replace(/\u0000/g, '').trim().slice(0, max);
}
function civilDate(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value ?? ''));
  if (!match) return null;
  const [year, month, day] = match.slice(1).map(Number);
  if (year < 2000 || year > 2100) return null;
  const probe = new Date(Date.UTC(year, month - 1, day));
  return probe.getUTCFullYear() === year && probe.getUTCMonth() + 1 === month && probe.getUTCDate() === day ? match[0] : null;
}
function instant(value) {
  if (value instanceof Date) return Number.isFinite(value.getTime()) ? value.toISOString() : null;
  const input = clean(value, 80);
  if (!input) return null;
  if (civilDate(input)) return new Date(input + 'T00:00:00+08:00').toISOString();
  // A collection timestamp needs a zone, so execution-host timezone never changes a date.
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,3})?)?(?:Z|[+-]\d{2}:?\d{2})$/i.test(input)) return null;
  if (!civilDate(input.slice(0, 10))) return null;
  const parsed = new Date(input);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString() : null;
}
function chinaDate(value) {
  const stamp = instant(value);
  if (!stamp) throw new Error('采集时间无效，需要包含时区的日期时间');
  return new Date(Date.parse(stamp) + 8 * 3600000).toISOString().slice(0, 10);
}
function monthsBefore(date, months) {
  const [year, month, day] = date.split('-').map(Number);
  const first = new Date(Date.UTC(year, month - 1 - months, 1));
  const last = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
  return new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth(), Math.min(day, last))).toISOString().slice(0, 10);
}
function boundedInt(value, fallback, minimum, maximum, label) {
  if (value == null || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < minimum || parsed > maximum) throw new Error(`${label}须为 ${minimum}–${maximum} 之间的整数`);
  return parsed;
}

function normalizeConfig(input = {}, now = new Date()) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Error('研究配置须为对象');
  const today = chinaDate(now);
  const rawKeywords = typeof input.keywords === 'string' ? input.keywords.split(/[\n,，;；]/) : input.keywords;
  if (!Array.isArray(rawKeywords)) throw new Error('请提供 1–8 个搜索关键词');
  if (rawKeywords.some(value => typeof value !== 'string')) throw new Error('搜索关键词须为文本');
  const keywords = [...new Set(rawKeywords.map(value => clean(value, 81)).filter(Boolean))];
  if (keywords.length < 1 || keywords.length > 8 || keywords.some(value => value.length > 80)) throw new Error('请提供 1–8 个非空关键词，每词不超过 80 字');
  const focus = clean(input.focus, 2001);
  if (focus.length > 2000) throw new Error('关注点不能超过 2000 字');
  const startDate = input.startDate == null || input.startDate === '' ? monthsBefore(today, 6) : civilDate(input.startDate);
  const endDate = input.endDate == null || input.endDate === '' ? today : civilDate(input.endDate);
  if (!startDate || !endDate) throw new Error('日期须为有效的 YYYY-MM-DD');
  if (startDate > endDate || endDate > today) throw new Error('日期须满足开始日期 ≤ 结束日期 ≤ 上海时区今天');
  const browserChannel = input.browserChannel || 'msedge';
  if (!['msedge', 'chrome', 'chromium'].includes(browserChannel)) throw new Error('浏览器须为 msedge、chrome 或 chromium');
  const collectImages = input.collectImages == null ? true : input.collectImages;
  if (typeof collectImages !== 'boolean') throw new Error('图片采集设置须为布尔值');
  const researchScope = input.researchScope == null ? 'custom' : input.researchScope;
  if (!['algorithm_internship', 'algorithm_career', 'custom'].includes(researchScope)) throw new Error('研究主题须为具身算法实习、算法求职或自定义范围');
  return {
    keywords, focus, startDate, endDate,
    maxNotes: boundedInt(input.maxNotes, 30, 1, 100, '帖子上限'),
    maxCommentsPerNote: boundedInt(input.maxCommentsPerNote, 50, 0, 200, '每帖评论上限'),
    maxSearchScrolls: boundedInt(input.maxSearchScrolls, 6, 1, 20, '搜索滚动上限'),
    maxCommentScrolls: boundedInt(input.maxCommentScrolls, 5, 0, 20, '评论滚动上限'),
    collectImages, maxImagesPerNote: boundedInt(input.maxImagesPerNote, 9, 0, 18, '每帖图片上限'), researchScope,
    browserChannel
  };
}

function dateResult(date, evidence, timestamp = null) {
  return { publishedAt: date ? timestamp || new Date(date + 'T00:00:00+08:00').toISOString() : null, publishedDate: date, dateEvidence: evidence };
}
function parseVisibleDate(value, collectedAt = new Date().toISOString()) {
  const shown = clean(value, 180).normalize('NFKC');
  const stamp = instant(collectedAt);
  if (!stamp) throw new Error('采集时间无效');
  const today = chinaDate(stamp);
  if (!shown) return dateResult(null, 'unknown');
  // The displayed edit time is not evidence for original publication.
  if (/编辑|修改|更新|\bedited\b|\bupdated\b/i.test(shown)) return dateResult(null, 'edited');
  const exact = /(?:^|[^\d])(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})(?:日)?(?!\d)/.exec(shown);
  if (exact) {
    const date = `${exact[1]}-${exact[2].padStart(2, '0')}-${exact[3].padStart(2, '0')}`;
    return civilDate(date) ? dateResult(date, 'exact') : dateResult(null, 'unknown');
  }
  if (/^(?:刚刚|just now)(?:\s|$)/i.test(shown)) return dateResult(today, 'relative', stamp);
  const ago = /(?:^|[^\d])(\d{1,5})\s*(秒|分钟|分|小时|时|天|日|周|个月|月)前/.exec(shown);
  if (ago) {
    const count = Number(ago[1]), unit = ago[2];
    if ((unit === '天' || unit === '日') && count > 366 || unit === '周' && count > 104 || (unit === '月' || unit === '个月') && count > 24) return dateResult(null, 'unknown');
    if (unit === '月' || unit === '个月') return dateResult(monthsBefore(today, count), 'relative');
    const multiplier = { 秒: 1000, 分钟: 60000, 分: 60000, 小时: 3600000, 时: 3600000, 天: DAY, 日: DAY, 周: 7 * DAY }[unit];
    const publishedAt = new Date(Date.parse(stamp) - count * multiplier).toISOString();
    return dateResult(chinaDate(publishedAt), 'relative', publishedAt);
  }
  const dayWord = /(今天|昨天|前天)(?:\s|$|\d)/.exec(shown);
  if (dayWord) {
    const offset = { 今天: 0, 昨天: 1, 前天: 2 }[dayWord[1]];
    const date = new Date(Date.parse(today + 'T00:00:00Z') - offset * DAY).toISOString().slice(0, 10);
    return dateResult(date, 'relative');
  }
  const monthDay = /(?:^|[^\d])(\d{1,2})\s*[-/.月]\s*(\d{1,2})(?:日)?(?!\d)/.exec(shown);
  if (monthDay) {
    let year = Number(today.slice(0, 4));
    let date = `${year}-${monthDay[1].padStart(2, '0')}-${monthDay[2].padStart(2, '0')}`;
    if (date > today) date = `${--year}${date.slice(4)}`;
    // Feb 29 may refer to an older leap year; it remains unconfirmed either way.
    for (let attempt = 0; !civilDate(date) && attempt < 3; attempt++) date = `${--year}${date.slice(4)}`;
    return civilDate(date) ? dateResult(date, 'month_day') : dateResult(null, 'unknown');
  }
  return dateResult(null, 'unknown');
}

function safeNoteURL(value, requestedID) {
  let parsed;
  try { parsed = new URL(String(value)); } catch { throw new Error('帖子链接无效'); }
  const pathMatch = /^\/(?:explore|discovery\/item)\/([a-f\d]{24})\/?$/i.exec(parsed.pathname);
  if (parsed.protocol !== 'https:' || parsed.hostname !== 'www.xiaohongshu.com' || parsed.username || parsed.password || parsed.port || !pathMatch) throw new Error('帖子链接须来自小红书允许的 HTTPS 帖子路径');
  const id = pathMatch[1].toLowerCase();
  if (requestedID && requestedID !== id) throw new Error('帖子 ID 与链接不一致');
  parsed.pathname = parsed.pathname.replace(/\/$/, '');
  parsed.hash = '';
  const allowed = new URLSearchParams();
  for (const key of ['xsec_token', 'xsec_source']) {
    const found = parsed.searchParams.get(key);
    if (found && found.length <= 2048) allowed.set(key, found);
  }
  parsed.search = allowed.toString();
  return { id, url: parsed.href };
}
function count(value) {
  if (value == null || value === '' || typeof value === 'boolean') return null;
  const found = /^(\d+(?:\.\d+)?)\s*(万|亿|[kKmM])?\+?$/.exec(clean(value, 30).normalize('NFKC').replace(/,/g, ''));
  if (!found) return null;
  const multiplier = { 万: 10000, 亿: 100000000, k: 1000, K: 1000, m: 1000000, M: 1000000 }[found[2]] || 1;
  const result = Math.round(Number(found[1]) * multiplier);
  return Number.isSafeInteger(result) && result >= 0 && result <= 1000000000 ? result : null;
}
function normalizedDate(raw, collectedAt) {
  // Persisted dates were resolved at their own original observation time. A later
  // merge must never reinterpret retained "昨天" or "3天前" against a newer capture.
  if (DATE_KINDS.has(raw.dateEvidence)) {
    if (raw.dateEvidence === 'edited' || raw.dateEvidence === 'unknown') return dateResult(null, raw.dateEvidence);
    const date = civilDate(raw.publishedDate) || (instant(raw.publishedAt) ? chinaDate(raw.publishedAt) : null);
    return dateResult(date, date ? raw.dateEvidence : 'unknown', date && instant(raw.publishedAt));
  }
  if (clean(raw.dateText, 180)) return parseVisibleDate(raw.dateText, collectedAt);
  return dateResult(null, 'unknown');
}
function normalizeComment(raw, collectedAt) {
  if (!raw || typeof raw !== 'object') return null;
  const text = clean(raw.text, 8000);
  if (!text) return null;
  const dates = normalizedDate(raw, collectedAt);
  const parentId = clean(raw.parentId, 128) || null;
  const id = clean(raw.id, 128) || 'content-' + crypto.createHash('sha256').update([parentId || '', text, dates.publishedDate || '', raw.dateText || ''].join('|')).digest('hex').slice(0, 24);
  return { id, parentId: parentId === id ? null : parentId, text, publishedAt: dates.publishedAt, publishedDate: dates.publishedDate, dateEvidence: dates.dateEvidence, dateText: clean(raw.dateText, 180), likes: count(raw.likes) };
}
function normalizeImage(raw, collectedAt) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || typeof raw.id !== 'string' || !/^[a-f\d]{64}$/.test(raw.id)) throw new Error('图片 ID 须为文件 SHA-256 的 64 位小写十六进制值');
  const page = boundedInt(raw.page, null, 1, 18, '图片页码');
  if (page === null) throw new Error('图片须包含 1–18 的页码');
  if (raw.kind != null && raw.kind !== 'page_capture') throw new Error('图片仅支持实际页面截图');
  if (raw.mimeType != null && raw.mimeType !== 'image/png') throw new Error('页面截图仅支持 PNG');
  const capturedAt = raw.capturedAt == null ? collectedAt : instant(raw.capturedAt);
  if (!capturedAt) throw new Error('图片采集时间无效');
  const image = { id: raw.id, page, kind: 'page_capture', mimeType: 'image/png', capturedAt, text: '', ocrState: 'not_performed' };
  for (const field of ['width', 'height']) if (raw[field] != null) image[field] = boundedInt(raw[field], null, 1, 20000, '图片尺寸');
  // Current captures contain pixels, not OCR. Arbitrary paths, remote source URLs
  // and caller-provided "OCR text" cannot become trusted image evidence.
  return image;
}
function imageRecords(raw, collectedAt) {
  if (raw.images != null && !Array.isArray(raw.images)) throw new Error('帖子图片须为数组');
  const records = new Map();
  const input = Array.isArray(raw.images) ? raw.images : [];
  for (const value of input.slice(0, 36)) {
    const image = normalizeImage(value, collectedAt), prior = records.get(image.id);
    if (!prior) records.set(image.id, image);
    else records.set(image.id, { ...(prior.capturedAt <= image.capturedAt ? image : prior), page: Math.min(prior.page, image.page) });
  }
  const byPage = new Map();
  for (const image of records.values()) {
    const previous = byPage.get(image.page);
    if (!previous || previous.capturedAt <= image.capturedAt) byPage.set(image.page, image);
  }
  const all = [...byPage.values()].sort((a, b) => a.page - b.page);
  const images = all.slice(0, 18), coverage = raw.imageCoverage || {};
  let state = COVERAGE_STATES.has(coverage.state) ? coverage.state : images.length ? 'partial' : 'not_opened';
  let reason = clean(coverage.reason, 600);
  if (images.length && state === 'not_opened') state = 'partial';
  if (!images.length && state === 'visible_end') { state = 'failed'; reason = reason || '没有保存到可用的页面截图'; }
  if (input.length > 36 || all.length > 18) { state = 'partial'; reason = clean(`${reason ? reason + '；' : ''}仅保留最多 18 张页面截图`, 600); }
  return { images, imageCoverage: { state, reason, visibleCount: images.length } };
}
function normalizeNote(raw, config) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('帖子须为对象');
  const requestedID = clean(raw.id, 30).toLowerCase();
  if (requestedID && !/^[a-f\d]{24}$/.test(requestedID)) throw new Error('帖子 ID 须为 24 位十六进制');
  const identity = safeNoteURL(raw.url, requestedID);
  const collectedAt = raw.collectedAt == null ? new Date().toISOString() : instant(raw.collectedAt);
  if (!collectedAt) throw new Error('帖子采集时间无效');
  const dates = normalizedDate(raw, collectedAt);
  const capturedImages = imageRecords(raw, collectedAt);
  const metrics = {};
  for (const key of ['likes', 'collects', 'comments', 'shares']) metrics[key] = count(raw.metrics?.[key]);
  const limit = config ? boundedInt(config.maxCommentsPerNote, 50, 0, 200, '每帖评论上限') : 200;
  const comments = [];
  const seen = new Map();
  let commentsTruncated = Array.isArray(raw.comments) && raw.comments.length > 500;
  for (const entry of (Array.isArray(raw.comments) ? raw.comments : []).slice(0, 500)) {
    const comment = normalizeComment(entry, collectedAt);
    if (!comment) continue;
    const prior = seen.get(comment.id);
    if (prior) { if (comment.text.length > prior.text.length) prior.text = comment.text; if (!prior.parentId) prior.parentId = comment.parentId; continue; }
    if (comments.length >= limit) { commentsTruncated = true; continue; }
    comments.push(comment); seen.set(comment.id, comment);
  }
  const coverage = raw.commentCoverage || {};
  let coverageState = COVERAGE_STATES.has(coverage.state) ? coverage.state : 'not_opened';
  let coverageReason = clean(coverage.reason, 600);
  if (commentsTruncated) {
    coverageState = limit ? 'partial' : 'not_opened';
    coverageReason = clean(`${coverageReason ? coverageReason + '；' : ''}仅保留配置上限 ${limit} 条评论`, 600);
  }
  const displayedTotal = count(coverage.displayedTotal) ?? metrics.comments;
  const keywords = [...new Set((Array.isArray(raw.keywords) ? raw.keywords : []).slice(0, 1000).map(word => clean(word, 80)).filter(Boolean))];
  return {
    ...identity, title: clean(raw.title, 500), text: clean(raw.text, 20000), ...dates,
    dateText: clean(raw.dateText, 180), keywords, metrics, comments, ...capturedImages,
    commentCoverage: { state: coverageState, visibleCount: comments.length, displayedTotal, reason: coverageReason },
    collectedAt
  };
}

function richer(a, b) { return (b || '').length > (a || '').length ? b : a; }
function betterDate(a, b) {
  const priority = { exact: 4, relative: 3, month_day: 2, edited: 1, unknown: 0 };
  return priority[b.dateEvidence] > priority[a.dateEvidence] ? b : a;
}
function mergePair(a, b) {
  const latest = a.collectedAt > b.collectedAt ? a : b;
  const dates = betterDate(a, b);
  const comments = [], byID = new Map();
  for (const comment of [...a.comments, ...b.comments]) {
    const previous = byID.get(comment.id);
    if (!previous) { const entry = { ...comment }; comments.push(entry); byID.set(entry.id, entry); }
    else {
      previous.text = richer(previous.text, comment.text);
      previous.parentId = previous.parentId || comment.parentId;
      previous.likes = Math.max(previous.likes ?? -1, comment.likes ?? -1); if (previous.likes < 0) previous.likes = null;
      const date = betterDate(previous, comment);
      previous.publishedAt = date.publishedAt; previous.publishedDate = date.publishedDate; previous.dateEvidence = date.dateEvidence; previous.dateText = date.dateText;
    }
  }
  const bounded = comments.slice(0, 200);
  const priorities = { visible_end: 4, partial: 3, failed: 2, not_opened: 1 };
  let coverage = priorities[a.commentCoverage.state] >= priorities[b.commentCoverage.state] ? a.commentCoverage : b.commentCoverage;
  // A later observation of additional displayed comments makes an earlier visible end stale.
  if (coverage.state === 'visible_end' && latest.commentCoverage.state === 'partial' && (latest.commentCoverage.displayedTotal || 0) > (coverage.displayedTotal || 0)) coverage = latest.commentCoverage;
  if (comments.length > bounded.length) coverage = { ...coverage, state: 'partial', reason: clean(`${coverage.reason ? coverage.reason + '；' : ''}合并后仅保留最多 200 条评论`, 600) };
  const metrics = {};
  for (const key of ['likes', 'collects', 'comments', 'shares']) { const max = Math.max(a.metrics[key] ?? -1, b.metrics[key] ?? -1); metrics[key] = max < 0 ? null : max; }
  const total = Math.max(a.commentCoverage.displayedTotal ?? -1, b.commentCoverage.displayedTotal ?? -1);
  const tokenURL = [latest.url, a.url, b.url].find(url => new URL(url).searchParams.has('xsec_token')) || latest.url;
  const allImages = imageRecords({ images: [...a.images, ...b.images] }, latest.collectedAt).images;
  let imageCoverage = priorities[a.imageCoverage.state] >= priorities[b.imageCoverage.state] ? a.imageCoverage : b.imageCoverage;
  // Images can be revisited independently of the body. Use the actual image
  // observation time, while keeping collectedAt as the body's original time.
  const imageTime = note => Math.max(0, ...note.images.map(image => Date.parse(image.capturedAt)));
  const imageLatest = imageTime(b) === imageTime(a) ? latest : imageTime(b) > imageTime(a) ? b : a;
  const priorImageIds = new Set((imageLatest === a ? b : a).images.map(image => image.id));
  if (imageCoverage.state === 'visible_end' && imageLatest.imageCoverage.state === 'partial' && imageLatest.images.some(image => !priorImageIds.has(image.id))) imageCoverage = imageLatest.imageCoverage;
  return { ...latest, url: tokenURL, title: richer(a.title, b.title), text: richer(a.text, b.text), publishedAt: dates.publishedAt, publishedDate: dates.publishedDate, dateEvidence: dates.dateEvidence, dateText: dates.dateText,
    keywords: [...new Set([...a.keywords, ...b.keywords])].slice(0, 1000), metrics, comments: bounded, images: allImages,
    imageCoverage: { ...imageCoverage, visibleCount: allImages.length },
    commentCoverage: { ...coverage, visibleCount: bounded.length, displayedTotal: total < 0 ? null : total } };
}
function mergeNotes(existing = [], incoming = []) {
  if (!Array.isArray(existing) || !Array.isArray(incoming)) throw new Error('帖子集合须为数组');
  const ordered = new Map();
  for (const raw of [...existing, ...incoming]) {
    const note = normalizeNote(raw);
    ordered.set(note.id, ordered.has(note.id) ? mergePair(ordered.get(note.id), note) : note);
  }
  return [...ordered.values()];
}
function safeCoverage(value, depth = 0) {
  if (depth > 4) return null;
  if (typeof value === 'string') return clean(value, 1200);
  if (typeof value === 'number') return Number.isFinite(value) ? Math.max(-1000000000, Math.min(1000000000, value)) : null;
  if (value == null || typeof value === 'boolean') return value;
  if (Array.isArray(value)) return value.slice(0, 50).map(item => safeCoverage(item, depth + 1));
  if (typeof value === 'object') {
    const result = {};
    for (const [key, entry] of Object.entries(value).slice(0, 50)) {
      if (/cookie|token|password|secret|storage|profile|session|author|user.?id|account|__proto__|constructor|prototype/i.test(key)) continue;
      result[clean(key, 80)] = safeCoverage(entry, depth + 1);
    }
    return result;
  }
  return null;
}
function buildDataset(config, notes, coverage = {}) {
  const generatedAt = new Date().toISOString();
  const normalizedConfig = normalizeConfig(config, generatedAt);
  const merged = normalizedConfig.researchScope === relevance.SCOPE ? relevance.rankNotes(mergeNotes([], notes)) : mergeNotes([], notes);
  const confirmed = [], undatedNotes = [], excludedNotes = [];
  for (const raw of merged) {
    const note = normalizeNote(raw, normalizedConfig);
    if (normalizedConfig.researchScope === relevance.SCOPE) note.relevance = relevance.classifyNote(note);
    if (!['exact', 'relative'].includes(note.dateEvidence) || !note.publishedDate) undatedNotes.push(note);
    else if (note.publishedDate < normalizedConfig.startDate || note.publishedDate > normalizedConfig.endDate) excludedNotes.push(note);
    else confirmed.push(note);
  }
  return { schemaVersion: 1, config: normalizedConfig, notes: confirmed, undatedNotes, excludedNotes, coverage: safeCoverage(coverage), generatedAt };
}

module.exports = { normalizeConfig, parseVisibleDate, normalizeNote, mergeNotes, buildDataset };
