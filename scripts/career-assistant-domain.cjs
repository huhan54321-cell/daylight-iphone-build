'use strict';
const { normalizeNote, normalizeConfig } = require('./xhs-core.cjs');
const { hash, fail } = require('./career-assistant-store.cjs');
const DAY = 86400000;
const text = (v, n = 300) => String(v ?? '').replace(/\0/g, '').trim().slice(0, n);
const words = (v, fallback = []) => [...new Set((Array.isArray(v) ? v : fallback).map(s => text(s, 80)).filter(Boolean))].slice(0, 16);
const day = now => new Date(Date.parse(now) + 8 * 3600000).toISOString().slice(0, 10);
function profile(raw, previous = {}) {
  const integer = (v, min, max) => v == null || v === '' ? null : Number.isInteger(Number(v)) && Number(v) >= min && Number(v) <= max ? Number(v) : (() => { throw fail('画像中的数字超出允许范围'); })();
  const result = { id: text(raw.id || previous.id || 'embodied', 100), name: text(raw.name || previous.name || '具身智能实习', 100),
    directions: words(raw.directions, previous.directions || ['具身智能', '机器人', 'VLA', '模仿学习', '机器人运控']),
    cities: words(raw.cities, previous.cities || ['杭州', '上海']), skills: words(raw.skills, previous.skills || []),
    graduationYear: integer(raw.graduationYear ?? previous.graduationYear, 2020, 2050), days: integer(raw.days ?? previous.days, 1, 7),
    months: integer(raw.months ?? previous.months, 1, 36), startDate: text(raw.startDate ?? previous.startDate, 10),
    enabled: raw.enabled ?? previous.enabled ?? true, version: (previous.version || 0) + 1 };
  if (!result.name || !result.directions.length || !/^[\w-]{1,100}$/.test(result.id) || typeof result.enabled !== 'boolean') throw fail('画像须包含名称、方向及有效 ID');
  if (result.startDate && (!/^\d{4}-\d{2}-\d{2}$/.test(result.startDate) || !Number.isFinite(Date.parse(result.startDate)))) throw fail('到岗日期格式无效');
  return result;
}
function matchJob(job, target) {
  const content = `${job.title} ${job.description || ''} ${(job.requirements || []).join(' ')} ${(job.tags || []).join(' ')}`.toLowerCase();
  const reasons = [], gaps = [], unknown = [];
  const hits = target.directions.filter(word => content.includes(word.toLowerCase()));
  if (!/实习|intern/i.test(`${job.title} ${job.jobType || ''}`)) gaps.push('实习身份未明确，不作为精准实习推荐');
  if (hits.length) reasons.push('方向相关：' + hits.join('、')); else gaps.push('未发现目标方向的直接证据');
  if (target.cities.length) {
    if (target.cities.some(city => (job.city || '').includes(city))) reasons.push('地点符合偏好');
    else if (!job.city || /未|不详/.test(job.city)) unknown.push('地点未明确');
    else gaps.push('地点不在优先城市');
  }
  for (const [field, need, label] of [['days', 'minDays', '每周天数'], ['months', 'minMonths', '实习时长']]) {
    if (target[field] && job[need] && target[field] < job[need]) gaps.push(`${label}不足：要求 ${job[need]}，可提供 ${target[field]}`);
    else if (!job[need]) unknown.push(label + '未明确');
    else if (!target[field]) unknown.push('个人' + label + '待填写');
    else reasons.push(label + '符合');
  }
  if (job.graduateYears?.length && target.graduationYear && !job.graduateYears.includes(target.graduationYear)) gaps.push('毕业年份不符');
  else if (!job.graduateYears?.length || !target.graduationYear) unknown.push('毕业年份条件待核查');
  if (target.startDate) unknown.push('到岗时间需与原帖核对：' + target.startDate);
  const skillHits = target.skills.filter(word => content.includes(word.toLowerCase()));
  if (skillHits.length) reasons.push('已有技能：' + skillHits.join('、'));
  if (job.verification !== 'full_jd') unknown.push('尚未取得完整岗位正文');
  if (job.status === 'closed' || job.status === 'historical') gaps.push('岗位已关闭或为历史信息');
  const lane = hits.length && !gaps.length && job.verification === 'full_jd' ? 'precise' : 'explore';
  return { profileID: target.id, lane, score: Math.max(0, Math.min(100, hits.length * 16 + skillHits.length * 6 + reasons.length * 5 - gaps.length * 12)), reasons, gaps, unknown };
}
function xhsConfig(targets, now) {
  const directions = words(targets.filter(p => p.enabled).flatMap(p => p.directions), ['具身智能']);
  const keywords = directions.slice(0, 5).map(s => s + ' 实习招聘');
  keywords.push((directions[0] || '具身智能') + ' 内推', (directions[1] || '机器人') + ' 招实习生');
  return normalizeConfig({ keywords: [...new Set(keywords)].slice(0, 8), researchScope: 'custom',
    focus: '寻找正在招聘的具身智能与机器人实习线索，排除个人求职和培训广告',
    startDate: day(new Date(Date.parse(now) - 89 * DAY).toISOString()), endDate: day(now),
    maxNotes: 30, maxCommentsPerNote: 0, maxCommentScrolls: 0, collectImages: false, maxImagesPerNote: 0, browserChannel: 'msedge' }, now);
}
function leadFromNote(raw, targets, previous, now) {
  const note = normalizeNote(raw, { maxCommentsPerNote: 0 });
  const content = `${note.title}\n${note.text}`;
  const recruiting = /招聘|招募|招[\s\S]{0,10}实习生|内推|简历.{0,8}(投|发)|投递[：:]|投递.{0,8}(邮箱|简历)|岗位[：:].{0,40}实习|hiring/i.test(content);
  const seeking = /求捞|求内推|求实习|求职帖|找实习|蹲实习/.test(note.title) || /本人.{0,20}(求职|找实习)/.test(content);
  const ad = /付费内推|保offer|保录取|训练营|课程推广|辅导班/.test(content);
  const experience = /面经|面试复盘|实习总结|实习体验|实习经历分享|实习经验|经验帖/.test(note.title);
  const directions = words(targets.flatMap(p => p.directions));
  const hits = directions.filter(word => content.toLowerCase().includes(word.toLowerCase()));
  const internship = /实习|intern/i.test(content);
  let category = !seeking && !ad && !experience && internship && hits.length ? (recruiting ? /转载|转发|搬运/.test(content) ? 'repost' : /内推/.test(content) ? 'referral' : 'recruitment' : note.text.length < 100 ? 'insufficient' : 'excluded') : 'excluded';
  const closed = /已招满|已经招满|停止招聘|岗位关闭|招聘结束|暂停招聘/.test(content);
  if (closed) category = 'closed';
  const confirmed = ['exact', 'relative'].includes(note.dateEvidence) && Boolean(note.publishedDate);
  const age = confirmed ? Math.floor((Date.parse(day(now)) - Date.parse(note.publishedDate)) / DAY) : null;
  const dateBucket = age === null ? 'unknown' : age < 0 || age > 89 ? 'historical' : age <= 29 ? 'recent' : 'within90';
  const company = /(?:公司|团队|实验室|部门)[：:]\s*([^\n，。；]{2,60})/.exec(content)?.[1] || null;
  const city = [...content.matchAll(/北京|上海|杭州|深圳|广州|苏州|南京|成都|武汉|合肥|远程/g)].map(m => m[0]);
  const conditions = content.split(/[\n。；]/).map(s => s.trim()).filter(s => /要求|每周|个月|到岗|在校|毕业|熟悉|掌握|负责|本科|硕士|博士/.test(s)).slice(0, 3).map(s => text(s, 220));
  const canonicalURL = `https://www.xiaohongshu.com/explore/${note.id}`;
  const contentHash = hash([note.title, note.text, note.publishedDate, note.dateEvidence]);
  return { id: note.id, title: note.title || /岗位[：:]\s*([^\n]{1,80})/.exec(note.text)?.[1] || '未命名帖子', url: note.url, canonicalURL,
    text: note.text, publishedDate: confirmed ? note.publishedDate : null, dateEvidence: note.dateEvidence, dateText: note.dateText,
    dateBucket, company, cities: [...new Set(city)], directions: hits, conditions, category,
    reason: category === 'insufficient' ? '可能相关，需查看原帖；尚未识别图片文字' : category === 'excluded' ? '非明确相关实习招聘：求职、经验、推广或主题信息不足' : `帖文提及${hits.join('、') || '招聘'}；身份与当前招聘有效性未核实`,
    firstSeenAt: previous?.firstSeenAt || note.collectedAt, checkedAt: note.collectedAt,
    read: previous?.read || false, saved: previous?.saved || false, ignored: previous?.ignored || false,
    linkedJobID: previous?.linkedJobID || null, opportunityID: previous?.opportunityID || null,
    contentHash, changed: Boolean(previous && previous.contentHash !== contentHash),
    relatedIDs: previous?.relatedIDs || [], lastRecheckedAt: previous?.lastRecheckedAt || null };
}
function report(leads, changedIDs, config, run, now) {
  leads = leads.map(l => refreshDateBucket(l, now));
  const eligible = leads.filter(l => !l.ignored && !['excluded', 'closed'].includes(l.category) && l.dateBucket !== 'historical');
  const order = { recent: 0, within90: 1, unknown: 2 };
  eligible.sort((a, b) => order[a.dateBucket] - order[b.dateBucket] || (b.publishedDate || '').localeCompare(a.publishedDate || '') || a.id.localeCompare(b.id));
  const changed = new Set(changedIDs);
  const rows = eligible.filter(l => changed.has(l.id));
  const publicRow = l => ({ ...l, text: undefined });
  return { id: run.id, generatedAt: now, title: `${day(now)} 招聘线索报告`, keywords: config.keywords,
    startDate: config.startDate, endDate: config.endDate, state: run.state, partial: run.state !== 'ok' || run.coverage?.partial === true,
    inspected: run.coverage?.detailsVisited || 0, message: rows.length ? `本轮取得 ${rows.length} 条新增或变化线索` : '本轮没有取得新增招聘线索；不代表平台没有相关招聘。',
    priority: rows.slice(0, 10).map(publicRow), leads: rows.map(publicRow), unknownDateCount: rows.filter(l => l.dateBucket === 'unknown').length,
    closedIDs: leads.filter(l => changed.has(l.id) && l.category === 'closed').map(l => l.id),
    coverage: run.coverage || {}, scopeNote: '来自有限关键词、账号可见页面及本轮预算；日期不明材料未计入近期招聘。' };
}
function refreshDateBucket(lead, now) {
  const age = lead.publishedDate ? Math.floor((Date.parse(day(now)) - Date.parse(lead.publishedDate)) / DAY) : null;
  return { ...lead, dateBucket: age === null ? 'unknown' : age < 0 || age > 89 ? 'historical' : age <= 29 ? 'recent' : 'within90' };
}
module.exports = { profile, matchJob, xhsConfig, leadFromNote, report, refreshDateBucket, day, hash, text, words, DAY };
