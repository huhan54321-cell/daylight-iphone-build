'use strict';
const { fail, hash } = require('./career-assistant-store.cjs');
const { normalizeJob, mergeJobs } = require('./career-core.cjs');

const stages = ['未投递', '准备材料', '已打招呼', '已发送简历', '已投递', '面试', 'Offer', '未通过', '已结束'];
const defaults = id => ({ id, saved: false, stage: '未投递', notes: '', nextAction: '', reminderAt: null, interview: null, revision: 0 });
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])])) : value;
const same = (a, b) => hash(canonical(a ?? null)) === hash(canonical(b ?? null));
function date(value) { return typeof value === 'string' && Number.isFinite(Date.parse(value)); }
function validatePatch(kind, raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || !Object.keys(raw).length) throw fail('没有可保存的跟进内容');
  const allowed = kind === 'followups' ? ['saved', 'stage', 'notes', 'nextAction', 'reminderAt', 'interview'] : ['saved', 'read', 'ignored'];
  if (Object.keys(raw).some(k => !allowed.includes(k))) throw fail('手机同步包含不支持的字段');
  for (const [k, v] of Object.entries(raw)) {
    if (['saved', 'read', 'ignored'].includes(k) && typeof v !== 'boolean') throw fail('收藏或阅读状态无效');
    if (k === 'stage' && !stages.includes(v)) throw fail('跟进阶段无效');
    if (['notes', 'nextAction'].includes(k) && (typeof v !== 'string' || v.length > (k === 'notes' ? 4000 : 200))) throw fail('跟进文字过长');
    if (k === 'reminderAt' && v !== null && !date(v)) throw fail('提醒时间无效');
    if (k === 'interview' && v !== null) {
      if (!v || typeof v !== 'object' || Array.isArray(v) || !date(v.start) || !date(v.end) || Date.parse(v.end) <= Date.parse(v.start) || Date.parse(v.end) - Date.parse(v.start) > 86400000) throw fail('面试起止时间无效');
      if (Object.keys(v).some(key => !['start', 'end', 'location', 'notes'].includes(key)) || ['location', 'notes'].some(key => v[key] !== undefined && (typeof v[key] !== 'string' || v[key].length > 2000))) throw fail('面试内容无效');
    }
  }
  return raw;
}
function resolveJob(store, id, raw) {
  if (store.get('jobs', id)) return id;
  if (!raw) throw fail('岗位已不在电脑资料中，请重新读取或保留本机记录', 404);
  // Import a historical phone record without inventing a new check time or source success.
  const normalized = normalizeJob(raw, raw.sourceID, raw.checkedAt);
  const jobs = mergeJobs(store.list('jobs'), [normalized]);
  const row = jobs.find(j => j.id === normalized.id || (j.sourceMembers || []).some(m => m.id === normalized.id) || [j.url, ...(j.relatedURLs || [])].includes(normalized.url));
  if (!row) throw fail('无法关联历史岗位，请核查原始链接');
  for (const job of jobs) store.put('jobs', job);
  return row.id;
}
function createMobileSync(store, now) {
  function change(kind, id, patch) {
    validatePatch(kind, patch);
    const old = store.get(kind, id) || (kind === 'followups' ? defaults(id) : null);
    if (!old) throw fail('招聘线索不存在', 404);
    return store.put(kind, { ...old, ...patch, revision: (old.revision || 0) + 1, updatedAt: now() });
  }
  function sync(body) {
    if (!Array.isArray(body.operations) || body.operations.length > 50) throw fail('一次最多同步 50 项修改');
    return { results: body.operations.map(op => {
      try { return store.transaction(() => {
        if (!op || typeof op.id !== 'string' || !/^[\w-]{8,100}$/.test(op.id) || !['followups', 'leads'].includes(op.kind) || typeof op.targetID !== 'string' || op.targetID.length > 200) throw fail('同步记录格式无效');
        const digest = hash(canonical(op)), previous = store.get('mobileOperations', op.id);
        if (previous) {
          if (previous.digest !== digest) throw fail('操作编号已使用，请重新确认修改', 409);
          return { ...previous.result, current: store.get(op.kind, previous.result.targetID) || previous.result.current };
        }
        validatePatch(op.kind, op.patch);
        if (!op.base || typeof op.base !== 'object' || Object.keys(op.patch).some(k => !Object.hasOwn(op.base, k))) throw fail('缺少修改前的内容');
        const id = op.kind === 'followups' ? resolveJob(store, op.targetID, op.job) : op.targetID;
        const current = store.get(op.kind, id) || (op.kind === 'followups' ? defaults(id) : null);
        if (!current) throw fail('招聘线索不存在', 404);
        const conflicts = Object.keys(op.patch).filter(k => !same(current[k], op.base[k]) && !same(current[k], op.patch[k]));
        if (conflicts.length) return { id: op.id, targetID: id, state: 'conflict', current, fields: conflicts, message: '电脑与手机修改了同一内容，请选择保留版本。' };
        const row = change(op.kind, id, op.patch);
        const result = { id: op.id, targetID: id, state: 'applied', current: row };
        store.put('mobileOperations', { id: op.id, digest, result, appliedAt: now() });
        return result;
      }); } catch (e) { return { id: op?.id, state: 'error', message: e.status ? e.message : '这项修改未同步，本机记录已保留。' }; }
    }) };
  }
  return { sync, change };
}
module.exports = { createMobileSync, defaults, validatePatch, stages };
