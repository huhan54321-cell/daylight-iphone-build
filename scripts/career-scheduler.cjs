'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const DEFAULT_CONFIG = Object.freeze({
  schemaVersion: 1, schedulingEnabled: true, intervalHours: 72, dailyRequestBudget: 80, maxRequestsPerRefresh: 24,
  maxQueriesPerSource: 3, pagesPerQuery: 2, maxDetailsPerSource: 8,
  // Short independent queries protect recall on platforms with literal keyword search.
  // Internship eligibility and capability precision are checked after discovery.
  cities: ['杭州', '上海'], keywords: ['具身智能', '模仿学习', '机器人仿真', '机械臂', '机器人软件', '运动控制', 'MuJoCo', '操作学习'],
  companies: ['群核科技', '西湖机器人', '灵西机器人', '西湖数智', '宇树科技', '云深处', '千寻智能', '有鹿机器人', '原力灵机', '五八智能', '峦启', '炬坤', '骅羲', '海康机器人', '宇泛', '阿里巴巴', '蚂蚁', '网易雷火'],
  browserCollectorEnabled: false, browserChannel: 'chromium', sources: {}
});
function boundedNumber(value, fallback, minimum, maximum) { const n = Number(value); return Number.isFinite(n) ? Math.max(minimum, Math.min(maximum, Math.floor(n))) : fallback; }
function strings(value, fallback, maximum) { return Array.isArray(value) && value.length ? [...new Set(value.slice(0, maximum).filter(s => typeof s === 'string').map(s => s.trim().slice(0, 100)).filter(Boolean))] : [...fallback]; }
function normalizeConfig(raw = {}) {
  return {
    ...DEFAULT_CONFIG, schedulingEnabled: raw.schedulingEnabled !== false,
    intervalHours: boundedNumber(raw.intervalHours, DEFAULT_CONFIG.intervalHours, 1, 168), dailyRequestBudget: boundedNumber(raw.dailyRequestBudget, 80, 10, 500), maxRequestsPerRefresh: boundedNumber(raw.maxRequestsPerRefresh, 24, 1, 48),
    maxQueriesPerSource: boundedNumber(raw.maxQueriesPerSource, 3, 1, 8), pagesPerQuery: boundedNumber(raw.pagesPerQuery, 2, 1, 3), maxDetailsPerSource: boundedNumber(raw.maxDetailsPerSource, 8, 0, 12),
    cities: strings(raw.cities, DEFAULT_CONFIG.cities, 4), keywords: strings(raw.keywords, DEFAULT_CONFIG.keywords, 16), companies: Array.isArray(raw.companies) ? strings(raw.companies, [], 40) : [...DEFAULT_CONFIG.companies],
    browserCollectorEnabled: raw.browserCollectorEnabled === true,
    browserChannel: ['chromium', 'chrome', 'msedge'].includes(raw.browserChannel) ? raw.browserChannel : 'chromium',
    sources: raw.sources && typeof raw.sources === 'object' && !Array.isArray(raw.sources) ? Object.fromEntries(Object.entries(raw.sources).filter(([key, value]) => /^[a-z-]+$/.test(key) && typeof value === 'boolean')) : {}
  };
}
function writeJSON(file, value) { fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 }); fs.writeFileSync(file + '.tmp', JSON.stringify(value, null, 2) + '\n', { mode: 0o600 }); fs.renameSync(file + '.tmp', file); }
function loadConfig(dataDir) {
  const file = path.join(dataDir, 'config.json');
  if (!fs.existsSync(file)) { const config = normalizeConfig(); writeJSON(file, config); return config; }
  return normalizeConfig(JSON.parse(fs.readFileSync(file, 'utf8')));
}
function chinaDay(iso) { return new Date(Date.parse(iso) + 8 * 3600000).toISOString().slice(0, 10); }
function tomorrowChina(iso) { const today = chinaDay(iso); return new Date(Date.parse(today + 'T00:00:00+08:00') + 86400000).toISOString(); }
function loadScheduler(dataDir, now) {
  const file = path.join(dataDir, 'scheduler.json');
  if (!fs.existsSync(file)) return { schemaVersion: 1, nextRunAt: now, lastRunAt: null, lastFinishedAt: null, daily: { day: chinaDay(now), requests: 0 }, sources: {} };
  const state = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (state.schemaVersion !== 1 || !state.sources || !state.daily) throw new Error('调度缓存格式无效，请保留原文件后检查');
  return state;
}
function saveScheduler(dataDir, state) { writeJSON(path.join(dataDir, 'scheduler.json'), state); }
function resetBudget(state, now) { const day = chinaDay(now); if (state.daily.day !== day) state.daily = { day, requests: 0 }; }
function remainingBudget(state, config, now) { resetBudget(state, now); return Math.max(0, config.dailyRequestBudget - state.daily.requests); }
function spendBudget(state, config, now, count = 1) { if (remainingBudget(state, config, now) < count) return false; state.daily.requests += count; return true; }
function queryPlan(config, cursor = {}, queryPages = {}) {
  const state = cursor && typeof cursor === 'object' ? { skill: 0, company: 0, other: 0, round: 0, ...cursor } : { skill: Number(cursor) || 0, company: 0, other: 0, round: 0 };
  const main = config.cities[0], others = config.cities.slice(1), selected = [], seen = new Set();
  const totalQueries = config.keywords.length * config.cities.length + config.companies.length;
  const count = Math.min(config.maxQueriesPerSource, totalQueries);
  for (let n = 0; selected.length < count && n < count * 6; n++) {
    const lane = (n + (config.maxQueriesPerSource < 3 ? state.round : 0)) % 3;
    let query;
    if (lane === 1 && config.companies.length) { const company = config.companies[state.company++ % config.companies.length]; query = { city: main, keyword: company, company }; }
    else if (lane === 2 && others.length) { const position = state.other++; query = { city: others[position % others.length], keyword: config.keywords[Math.floor(position / others.length) % config.keywords.length], company: null }; }
    else query = { city: main, keyword: config.keywords[state.skill++ % config.keywords.length], company: null };
    const queryID = crypto.createHash('sha256').update(query.city + '|' + query.keyword).digest('hex').slice(0, 16);
    if (seen.has(queryID)) continue;
    seen.add(queryID); selected.push({ ...query, queryID, pageStart: Math.max(2, Math.min(100, Number(queryPages[queryID]) || 2)) });
  }
  state.round++;
  return { queries: selected, totalQueries, nextCursor: state };
}
function shouldAttempt(state, sourceID, now, force) { return force || !state.sources[sourceID]?.nextAttemptAt || Date.parse(state.sources[sourceID].nextAttemptAt) <= Date.parse(now); }
function recordAttempt(state, sourceID, result, now, config, coverage) {
  const prior = state.sources[sourceID] || { failureCount: 0, queryCursor: 0 };
  const successful = result.state === 'ok';
  const failureCount = successful || result.state === 'not_configured' ? 0 : Math.min(12, prior.failureCount + 1);
  let wait = successful ? config.intervalHours * 3600000 : ['not_configured','login_required'].includes(result.state) ? 24 * 3600000 : result.state === 'blocked' ? Math.min(24 * 3600000, 3600000 * (2 ** Math.max(0, failureCount - 1))) : Math.min(config.intervalHours * 3600000, 5 * 60000 * (2 ** Math.max(0, failureCount - 1)));
  // The chosen collection cadence is also the minimum automatic retry interval.
  // Manual refresh still bypasses this through shouldAttempt(..., true).
  wait = Math.max(wait, config.intervalHours * 3600000);
  if (remainingBudget(state, config, now) === 0) wait = Math.max(wait, Date.parse(tomorrowChina(now)) - Date.parse(now));
  state.sources[sourceID] = { ...prior, failureCount, lastAttemptAt: now, lastSuccessAt: successful ? now : prior.lastSuccessAt || null, nextAttemptAt: new Date(Date.parse(now) + wait).toISOString(), state: result.state,
    queryCursor: successful && coverage ? coverage.nextCursor : prior.queryCursor, queryPages: { ...(prior.queryPages || {}), ...(coverage?.queryPages || {}) }, detailCursor: successful && coverage ? coverage.nextDetailCursor ?? prior.detailCursor ?? 0 : prior.detailCursor || 0, coverage: coverage || prior.coverage || null };
}
function nextRunAt(state, config, now) {
  const future = Object.values(state.sources).map(s => Date.parse(s.nextAttemptAt)).filter(n => Number.isFinite(n));
  const normal = Date.parse(now) + config.intervalHours * 3600000;
  return new Date(future.length ? Math.max(normal, Math.min(...future)) : normal).toISOString();
}
module.exports = { DEFAULT_CONFIG, normalizeConfig, loadConfig, chinaDay, tomorrowChina, loadScheduler, saveScheduler, remainingBudget, spendBudget, queryPlan, shouldAttempt, recordAttempt, nextRunAt };
