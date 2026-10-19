'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { AssistantStore, hash, fail } = require('./career-assistant-store.cjs');
const domain = require('./career-assistant-domain.cjs');
const { createMobileSync, defaults: followupDefaults } = require('./career-mobile-sync.cjs');
const { mergeJobs, normalizeJob, safeRelatedURL } = require('./career-core.cjs');
const { runXHSCollector } = require('./xhs-browser-runner.cjs');
const { loadHistory } = require('./xhs-history.cjs');
const { normalizeConfig: collectorConfig } = require('./career-scheduler.cjs');

function createCareerAssistant(options) {
  const now = options.now || (() => new Date().toISOString());
  const store = new AssistantStore(options.dataDir);
  const mobile = createMobileSync(store, now);
  const xhsDir = options.xhsDir || path.resolve(__dirname, '../data/xhs-private');
  const runner = options.xhsRunner || runXHSCollector;
  const adapters = options.applicationAdapters || {};
  let active = null, timer = null, stopped = false;
  if (!store.list('profiles').length) store.put('profiles', domain.profile({}));
  for (const source of options.getFeed().sources || []) if (!store.get('sources', source.id)) store.put('sources', { ...source, capabilities: capabilities(source.id) });
  if (!store.get('sources', 'xiaohongshu')) store.put('sources', { id: 'xiaohongshu', name: '小红书招聘线索', state: 'not_checked', count: 0, message: '尚未运行本次检索；可迁移历史资料或开始发现。', lastSuccessAt: null });
  for (const task of store.list('tasks').filter(t => t.state === 'running')) store.put('tasks', { ...task, state: 'interrupted', finishedAt: now(), message: '服务重启，本轮中断；已经保存的结果仍可查看。' });
  for (const a of store.list('applications').filter(a => a.state === 'executing')) store.put('applications', { ...a, state: 'unknown', message: '执行期间服务中断，请到原站核查；不会自动重试。' });
  if (store.get('settings', 'ai')?.state === 'running') store.put('settings', { id: 'ai', state: 'interrupted', message: '上次分析被中断；规则结果保留，可重新发起。' });
  const get = (kind, id) => { const value = store.get(kind, id); if (!value) throw fail('记录不存在', 404); return value; };
  const meta = () => store.get('settings', 'schedule') || { id: 'schedule', enabled: true, lastDay: null, lastRecheckAt: null, lastRefreshAt: null };
  function capabilities(sourceID) {
    const adapter = adapters[sourceID];
    const ready = adapter?.verifiedAt && typeof adapter?.inspect === 'function';
    return { discover: true, detail: true, fill: Boolean(ready && adapter?.fill), submit: Boolean(ready && adapter?.submit), receipt: Boolean(ready && adapter?.submit), verifiedAt: adapter?.verifiedAt || null };
  }
  function syncFeed(feed) {
    return store.transaction(() => {
      const jobs = mergeJobs(store.list('jobs'), feed.jobs || []);
      for (const job of jobs) store.put('jobs', job);
      for (const source of feed.sources || []) store.put('sources', { ...source, capabilities: capabilities(source.id) });
      store.put('settings', { id: 'legacy-feed', generatedAt: feed.generatedAt });
      return jobs;
    });
  }
  function snapshot() {
    const profiles = store.list('profiles');
    const jobs = store.list('jobs').map(job => ({ ...job, matches: profiles.filter(p => p.enabled).map(p => domain.matchJob(job, p)), followUp: store.get('followups', job.id) || followupDefaults(job.id) }));
    const tasks = store.list('tasks').sort((a, b) => b.startedAt.localeCompare(a.startedAt)).slice(0, 30);
    const reports = store.list('reports').sort((a, b) => b.generatedAt.localeCompare(a.generatedAt));
    return { schemaVersion: 2, generatedAt: now(), online: true, profiles, jobs, sources: store.list('sources'),
      leads: store.list('leads').map(({ text, ...lead }) => domain.refreshDateBucket(lead, now())), reports: reports.slice(0, 60).map(({ leads, priority, ...r }, index) => ({ ...r, count: leads.length, priority, ...(index < 10 ? { leads } : {}) })),
      materials: store.list('materials').map(({ attachment, ...m }) => ({ ...m, attachment: attachment ? { name: attachment.name, hash: attachment.hash, size: attachment.size } : null })),
      applications: store.list('applications'), opportunities: store.list('opportunities'), tasks, schedule: meta(),
      ai: store.get('settings', 'ai') || { id: 'ai', state: 'not_checked', message: '本机 Codex 尚未验证；规则筛选正常可用。' } };
  }
  function ingestNotes(notes, config, result) {
    const changed = [];
    store.transaction(() => {
      for (const raw of notes) {
        try {
          const old = store.get('leads', raw.id);
          const incoming = { ...raw };
          // An unreadable refresh cannot erase previously captured prose or imply closure.
          if (old?.text && !incoming.text) incoming.text = old.text;
          const lead = domain.leadFromNote(incoming, store.list('profiles'), old, now());
          if (!old || old.contentHash !== lead.contentHash) changed.push(lead.id);
          if (result.recheck) lead.lastRecheckedAt = now();
          const similar = store.list('leads').filter(l => l.id !== lead.id && lead.text.length > 80 && l.text.replace(/\s/g, '') === lead.text.replace(/\s/g, ''));
          lead.relatedIDs = similar.map(l => l.id);
          store.put('leads', lead);
          for (const related of similar) store.put('leads', { ...related, relatedIDs: [...new Set([...related.relatedIDs, lead.id])] });
        } catch (error) { if (error.code?.startsWith('ERR_SQLITE')) throw error; result.invalidCount = (result.invalidCount || 0) + 1; }
      }
      const row = domain.report(store.list('leads'), changed, config, result, now());
      store.put('reports', row);
      store.put('sources', { id: 'xiaohongshu', name: '小红书招聘线索', state: result.state, message: result.message || row.message,
        lastAttemptAt: now(), lastSuccessAt: result.state === 'ok' ? now() : store.get('sources', 'xiaohongshu')?.lastSuccessAt || null,
        count: store.list('leads').filter(l => !['closed', 'excluded'].includes(l.category)).length,
        coverage: { ...result.coverage, invalidCount: result.invalidCount || 0 }, capabilities: { discover: true, detail: true, fill: false, submit: false, receipt: false } });
    });
    return changed;
  }
  async function collectXHS(task, recheck = false) {
    const config = domain.xhsConfig(store.list('profiles'), now());
    const source = store.get('sources', 'xiaohongshu');
    if (['login_required', 'blocked'].includes(source?.state) && !task.resumeSources) return { state: source.state, message: '请在电脑完成登录或验证，再点击恢复来源。' };
    let targets = [];
    if (recheck) {
      targets = store.list('leads').filter(l => l.saved && l.category !== 'closed').sort((a, b) => (a.lastRecheckedAt || '').localeCompare(b.lastRecheckedAt || '')).slice(0, 10);
      if (!targets.length) return { state: 'ok' };
    }
    const handle = runner({ dataDir: xhsDir, mode: recheck ? 'recheck' : 'collect',
      config: { ...config, excludeNoteIds: store.list('leads').map(l => l.id), recheckNotes: targets.map(l => ({ id: l.id, url: l.url, title: l.title })) },
      onProgress: progress => store.put('tasks', { ...get('tasks', task.id), message: progress.message, progress }) });
    if (active) active.cancel = handle.cancel;
    const result = await handle.promise;
    if (stopped) return result;
    ingestNotes(result.notes || [], config, { ...result, id: crypto.randomUUID(), recheck });
    return result;
  }
  function startRefresh({ sourceID, resumeSources = false } = {}) {
    if (active) return get('tasks', active.id);
    if (!store.list('profiles').some(p => p.enabled)) throw fail('请先启用至少一个求职目标', 409);
    if (sourceID && !['jobs', 'xiaohongshu'].includes(sourceID)) throw fail('未知刷新来源');
    if (meta().lastRefreshAt && Date.parse(now()) - Date.parse(meta().lastRefreshAt) < (options.cooldownMs ?? 60000)) throw fail('请至少间隔一分钟刷新', 429);
    const task = { id: crypto.randomUUID(), kind: 'refresh', state: 'running', startedAt: now(), message: '开始增量发现', resumeSources };
    store.put('tasks', task); store.put('settings', { ...meta(), lastRefreshAt: now() });
    active = { id: task.id, promise: null };
    active.promise = (async () => {
      const failures = [];
      if (!sourceID || sourceID === 'jobs') {
        try {
          const targets = store.list('profiles').filter(p => p.enabled);
          const existing = options.getCollectorConfig?.() || {};
          const blocked = store.list('sources').filter(s => ['login_required', 'blocked'].includes(s.state));
          const sourceSwitches = { ...existing.sources, official: true, boss: true, 'shixiseng-public': true };
          if (!resumeSources) for (const s of blocked) if (s.id !== 'xiaohongshu') sourceSwitches[s.id] = false;
          const settings = collectorConfig({ ...existing, publicDiscovery: true, keywords: targets.flatMap(p => p.directions), cities: targets.flatMap(p => p.cities), sources: sourceSwitches });
          const feed = await options.refreshJobs(settings);
          if (!stopped) { syncFeed(feed); for (const s of feed.sources || []) if (!['ok', 'not_configured'].includes(s.state)) failures.push(s.name); }
        } catch { failures.push('岗位来源'); }
      }
      if (!stopped && (!sourceID || sourceID === 'xiaohongshu')) {
        try {
          const result = await collectXHS(task);
          if (result.state !== 'ok') failures.push('小红书');
          const schedule = meta();
          if (result.state === 'ok' && (!schedule.lastRecheckAt || Date.parse(now()) - Date.parse(schedule.lastRecheckAt) >= 7 * domain.DAY)) {
            const rechecked = await collectXHS(task, true);
            if (!stopped && rechecked.state === 'ok') store.put('settings', { ...meta(), lastRecheckAt: now() });
          }
        } catch { failures.push('小红书'); if (!stopped) store.put('sources', { ...(store.get('sources', 'xiaohongshu') || { id: 'xiaohongshu', name: '小红书招聘线索', count: 0 }), state: 'error', lastAttemptAt: now(), message: '采集异常，原报告保留。' }); }
      }
      if (!stopped) store.put('tasks', { ...get('tasks', task.id), state: failures.length ? 'partial' : 'completed', finishedAt: now(), message: failures.length ? `${failures.join('、')}未全部完成，请查看来源状态；已有结果保留。` : '本轮增量发现完成' });
    })().finally(() => { active = null; });
    return task;
  }
  function migrationPreview() {
    const feed = options.getFeed();
    let notes = [], historyError = null;
    try { if (fs.existsSync(path.join(xhsDir, 'history.json'))) notes = loadHistory(xhsDir); } catch { historyError = '小红书历史无法读取，原文件保留；本次不迁移该来源。'; }
    const payload = { feed, notes };
    const fingerprint = hash({ jobs: feed.jobs, sources: feed.sources, notes });
    return { id: fingerprint, jobs: feed.jobs?.length || 0, notes: notes.length, historyError, alreadyImported: Boolean(store.get('migrations', fingerprint)), payload };
  }
  function material(raw) {
    const id = raw.id || crypto.randomUUID(), previous = store.get('materials', id);
    if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,100}$/.test(id)) throw fail('材料 ID 无效');
    const content = domain.text(raw.content, 40000), title = domain.text(raw.title, 160);
    if (!title || !content || raw.confirmedFacts !== true) throw fail('请填写材料名称与内容，并确认仅包含真实经历');
    let attachment = previous?.attachment || null;
    if (raw.attachment === null) attachment = null;
    else if (raw.attachment) {
      const a = raw.attachment, bytes = Buffer.from(a.base64 || '', 'base64');
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(a.base64 || '') || bytes.length > 2 * 1024 * 1024 || !bytes.subarray(0, 5).equals(Buffer.from('%PDF-'))) throw fail('附件须为不超过 2 MB 的 PDF');
      attachment = { name: domain.text(a.name, 160), base64: bytes.toString('base64'), size: bytes.length, hash: hash(bytes.toString('base64')) };
    }
    const row = { id, title, content, attachment, version: (previous?.version || 0) + 1, updatedAt: now(), confirmedFacts: true, contentHash: hash([content, attachment?.hash]) };
    store.transaction(() => {
      store.put('materials', row); store.put('materialVersions', { ...row, id: `${id}:${row.version}`, materialID: id });
      for (const a of store.list('applications').filter(a => a.materialID === id && ['draft', 'approved'].includes(a.state))) store.put('applications', { ...a, state: 'draft', approvalHash: null, message: '材料已变化，请重新查看并批准。' });
    });
    return row;
  }
  async function prepareApplication(raw) {
    const job = get('jobs', raw.jobID), m = get('materials', raw.materialID);
    if (job.status === 'closed' || job.status === 'historical') throw fail('岗位已经关闭或属于历史资料');
    const previous = raw.id ? get('applications', raw.id) : null;
    if (previous && !['draft', 'approved'].includes(previous.state)) throw fail('该申请已经进入执行或跟踪阶段', 409);
    const duplicate = store.list('applications').find(a => a.jobID === job.id && (!previous || a.id !== previous.id) && !['cancelled', 'rejected'].includes(a.state));
    if (duplicate) throw fail('该岗位已有申请，请继续已有记录', 409);
    if (!['greeting', 'send_resume', 'submit'].includes(raw.action)) throw fail('请选择打招呼、发送简历或正式提交');
    const fields = raw.fields || {};
    if (typeof fields !== 'object' || Array.isArray(fields) || Object.keys(fields).length > 100 || Object.entries(fields).some(([k, v]) => k.length > 100 || typeof v !== 'string' || v.length > 2000)) throw fail('表单字段格式无效');
    const adapter = adapters[job.sourceID];
    const form = capabilities(job.sourceID).submit ? await adapter.inspect({ job, material: m, fields }) : null;
    if (form && (typeof form.hash !== 'string' || !form.hash)) throw fail('平台没有提供可核对的表单版本', 409);
    const row = { id: previous?.id || crypto.randomUUID(), jobID: job.id, jobTitle: job.title, company: job.company, url: job.url,
      materialID: m.id, materialTitle: m.title, materialVersion: m.version, materialHash: m.contentHash,
      materialContent: m.content, attachment: m.attachment ? { name: m.attachment.name, hash: m.attachment.hash, size: m.attachment.size } : null,
      jobHash: job.contentHash, formHash: form?.hash || null, fields, action: raw.action, state: 'draft', approvalHash: null, revision: (previous?.revision || 0) + 1,
      createdAt: previous?.createdAt || now(), updatedAt: now(), capability: capabilities(job.sourceID), message: '请核对岗位、材料、附件及表单内容。' };
    row.reviewHash = hash([row.jobHash, row.materialHash, row.materialVersion, row.formHash, row.fields, row.action, row.url, row.revision]);
    return store.transaction(() => {
      if (get('materials', m.id).version !== m.version || get('jobs', job.id).contentHash !== job.contentHash) throw fail('准备审核期间材料或岗位已变化，请重试', 409);
      const current = previous ? get('applications', previous.id) : null;
      if (current && (current.revision !== previous.revision || !['draft', 'approved'].includes(current.state))) throw fail('申请已被更新，请重新读取', 409);
      if (!previous && store.list('applications').some(a => a.jobID === job.id && !['cancelled', 'rejected'].includes(a.state))) throw fail('该岗位已有申请，请继续已有记录', 409);
      store.event('prepare_application', row.id, now());
      return store.put('applications', row);
    });
  }
  function approve(id, body) {
    return store.transaction(() => {
      const a = get('applications', id), m = get('materials', a.materialID), job = get('jobs', a.jobID);
      if (!['draft', 'approved'].includes(a.state)) throw fail('该申请无法重复批准', 409);
      if (body.reviewHash !== a.reviewHash || m.version !== a.materialVersion || job.contentHash !== a.jobHash) throw fail('岗位或材料已经变化，请重新生成审核内容', 409);
      if (body.confirmed !== true) throw fail('需要确认本次审核内容');
      store.event('approve_application', id, now());
      return store.put('applications', { ...a, state: 'approved', approvedAt: now(), approvalHash: a.reviewHash, message: a.capability.submit ? '已批准，等待执行' : '已审核；此来源未开放自动提交，请到原页处理后记录结果。' });
    });
  }
  async function execute(id) {
    const a = get('applications', id);
    if (['executing', 'unknown', 'submitted', 'greeting_sent', 'resume_sent'].includes(a.state)) return a;
    const job = get('jobs', a.jobID), m = get('materials', a.materialID), adapter = adapters[job.sourceID];
    if (a.state !== 'approved' || a.approvalHash !== a.reviewHash || m.version !== a.materialVersion || job.contentHash !== a.jobHash) throw fail('批准已失效，请重新审核', 409);
    if (!capabilities(job.sourceID).submit) throw fail('该来源尚未通过真实投递适配验证，请在原页处理', 409);
    store.put('applications', { ...a, state: 'executing', executionID: a.reviewHash });
    try {
      const form = await adapter.inspect({ job, material: m, fields: a.fields });
      if (form.hash !== a.formHash || get('materials', m.id).version !== m.version || get('jobs', job.id).contentHash !== job.contentHash) return store.put('applications', { ...a, state: 'draft', approvalHash: null, message: '网页表单、岗位或材料已变化，本次未提交，请重新审核。' });
      const result = await adapter.submit({ job, material: m, fields: a.fields, action: a.action, idempotencyKey: a.reviewHash });
      const confirmed = result?.confirmed === true && typeof result.receipt === 'string' && result.receipt.length > 0;
      return store.put('applications', { ...get('applications', id), state: confirmed ? ({ greeting: 'greeting_sent', send_resume: 'resume_sent', submit: 'submitted' }[a.action]) : 'unknown', receipt: domain.text(result?.receipt, 2000), updatedAt: now(), message: confirmed ? '已取得平台回执' : '提交结果不明，请到原站核查；不会自动重试。' });
    } catch { return store.put('applications', { ...get('applications', id), state: 'unknown', updatedAt: now(), message: '执行未取得明确回执，请到原站核查；不会自动重试。' }); }
  }
  async function handle(method, route, body = {}) {
    const pieces = route.replace(/^\/v2\/career\/?/, '').split('/').filter(Boolean);
    const [resource, id, action] = pieces;
    if (method === 'GET' && resource === 'snapshot') return snapshot();
    if (method === 'POST' && resource === 'sync') return mobile.sync(body);
    if (method === 'GET' && resource === 'applications' && action === 'review') {
      const a = get('applications', id), material = get('materialVersions', a.materialID + ':' + a.materialVersion);
      return { ...a, material, job: get('jobs', a.jobID), valid: a.materialVersion === get('materials', a.materialID).version && a.jobHash === get('jobs', a.jobID).contentHash };
    }
    if (method === 'POST' && resource === 'applications' && action === 'request-changes') {
      const a = get('applications', id);
      if (!['draft', 'approved'].includes(a.state) || a.reviewHash !== body.reviewHash) throw fail('审核内容已变化，请重新读取', 409);
      return store.put('applications', { ...a, state: 'draft', approvalHash: null, revision: a.revision + 1, reviewHash: hash([a.reviewHash, a.revision + 1]), reviewNote: domain.text(body.note, 2000), message: '手机请求修改，请在电脑重新准备审核单。', updatedAt: now() });
    }
    if (method === 'GET' && resource === 'migration') { const { payload, ...preview } = migrationPreview(); return preview; }
    if (method === 'POST' && resource === 'migration') {
      const preview = migrationPreview();
      if (preview.id !== body.previewID) throw fail('历史数据已经变化，请重新预览', 409);
      if (preview.alreadyImported) return { imported: false, message: '这份资料已经迁移' };
      const backup = store.backup();
      store.transaction(() => {
        syncFeed(preview.payload.feed);
        if (preview.payload.notes.length) ingestNotes(preview.payload.notes, domain.xhsConfig(store.list('profiles'), now()), { id: crypto.randomUUID(), state: 'imported', message: '历史资料迁移，本次没有访问平台。', coverage: { detailsVisited: 0, partial: true } });
        store.put('migrations', { id: preview.id, importedAt: now(), backup });
      });
      return { imported: true, backup };
    }
    if (method === 'POST' && resource === 'refresh') return startRefresh(body);
    if (method === 'POST' && resource === 'browser' && id === 'import') {
      if (!['boss', 'shixiseng-public', 'official'].includes(body.sourceID) || !Array.isArray(body.jobs) || !body.jobs.length || body.jobs.length > 40) throw fail('请导入 1–40 条当前网页可见的岗位');
      const records = body.jobs.map(raw => normalizeJob({ ...raw, status: 'unconfirmed' }, body.sourceID, now()));
      syncFeed({ jobs: records, sources: [{ id: body.sourceID, name: records[0].sourceName, state: 'partial', count: records.length,
        lastAttemptAt: now(), lastSuccessAt: now(), message: '本人浏览器当前页面读取；仅覆盖实际可见内容，未完成全站搜索。', coverage: { partial: true, mode: 'browser_assisted', detailsRun: records.filter(r => r.verification === 'full_jd').length } }] });
      return { imported: records.length };
    }
    if (method === 'POST' && resource === 'profiles') return store.put('profiles', domain.profile(body, body.id ? store.get('profiles', body.id) || {} : {}));
    if (method === 'POST' && resource === 'materials') return material(body);
    if (method === 'GET' && resource === 'materials' && id) return get('materials', id);
    if (method === 'GET' && resource === 'materialVersions') return store.list('materialVersions').filter(v => v.materialID === id);
    if (method === 'POST' && resource === 'applications' && !id) return prepareApplication(body);
    if (method === 'POST' && resource === 'applications' && action === 'approve') return approve(id, body);
    if (method === 'POST' && resource === 'applications' && action === 'execute') return execute(id);
    if (method === 'POST' && resource === 'applications' && action === 'status') {
      const a = get('applications', id);
      if (a.state === 'executing') throw fail('执行中不能修改状态', 409);
      if (!['draft', 'cancelled', 'greeting_sent', 'resume_sent', 'submitted', 'interview', 'offer', 'rejected', 'unknown'].includes(body.state)) throw fail('状态无效');
      if (body.interviewAt && !Number.isFinite(Date.parse(body.interviewAt))) throw fail('面试时间无效');
      return store.put('applications', { ...a, state: body.state, approvalHash: null, interviewAt: body.interviewAt || null, receipt: domain.text(body.receipt, 2000), updatedAt: now(), message: '由本人记录，非自动取得的平台回执。' });
    }
    if (method === 'POST' && resource === 'jobs' && action === 'followup') {
      get('jobs', id);
      return mobile.change('followups', id, body);
    }
    if (method === 'POST' && resource === 'leads' && id) {
      const lead = get('leads', id);
      if (action === 'opportunity') {
        if (lead.opportunityID) return get('opportunities', lead.opportunityID);
        const opportunity = { id: crypto.randomUUID(), leadID: id, title: lead.title, url: lead.url, state: 'pending_verification', createdAt: now(), linkedJobID: null };
        store.transaction(() => { store.put('opportunities', opportunity); store.put('leads', { ...lead, opportunityID: opportunity.id }); });
        return opportunity;
      }
      const changes = {};
      for (const key of ['saved', 'read', 'ignored']) if (body[key] !== undefined) { if (typeof body[key] !== 'boolean') throw fail('线索状态无效'); changes[key] = body[key]; }
      return store.put('leads', { ...lead, ...changes });
    }
    if (method === 'POST' && resource === 'opportunities' && action === 'link') {
      const opportunity = get('opportunities', id), job = get('jobs', body.jobID);
      return store.transaction(() => { store.put('leads', { ...get('leads', opportunity.leadID), linkedJobID: job.id }); return store.put('opportunities', { ...opportunity, linkedJobID: job.id, state: 'linked' }); });
    }
    if (method === 'GET' && resource === 'reports' && id) return get('reports', id);
    if (method === 'GET' && ['profiles', 'jobs', 'leads', 'sources', 'applications', 'tasks', 'opportunities', 'reports'].includes(resource)) return snapshot()[resource];
    if (method === 'POST' && resource === 'backup') return store.backup();
    if (method === 'GET' && resource === 'export') return store.export();
    if (method === 'POST' && resource === 'restore') {
      if (active) throw fail('请等待当前任务完成后恢复', 409);
      if (body.schemaVersion !== 2 || !Array.isArray(body.records) || body.records.length > 30000) throw fail('备份格式无效');
      const allowed = new Set(['profiles','jobs','sources','leads','reports','materials','materialVersions','applications','opportunities','followups','tasks','settings','migrations','aiCache','mobileOperations']);
      for (const r of body.records) {
        if (!r || !allowed.has(r.kind) || typeof r.value?.id !== 'string' || !r.value.id || r.value.id.length > 200 || Array.isArray(r.value)) throw fail('备份记录无效');
        const v = r.value;
        const arrays = { profiles: ['directions','cities','skills'], reports: ['leads','priority'], leads: ['relatedIDs','directions','cities','conditions'] }[r.kind] || [];
        if (arrays.some(key => !Array.isArray(v[key]))) throw fail('备份字段结构无效');
        if (r.kind === 'tasks' && typeof v.startedAt !== 'string') throw fail('备份任务时间无效');
        if (['materials', 'materialVersions'].includes(r.kind) && (typeof v.content !== 'string' || !Number.isInteger(v.version) || v.version < 1)) throw fail('备份材料版本无效');
      }
      const backup = store.backup();
      store.transaction(() => { for (const r of body.records) {
        let value = r.value;
        if (r.kind === 'applications') value = { ...value, state: value.state === 'executing' ? 'unknown' : value.state === 'approved' ? 'draft' : value.state, approvalHash: null };
        if (r.kind === 'tasks' && value.state === 'running') value = { ...value, state: 'interrupted', message: '已从备份恢复，本轮未继续执行。' };
        if (r.kind === 'settings' && value.id === 'ai' && value.state === 'running') value = { ...value, state: 'interrupted', message: '已从备份恢复，可重新发起分析。' };
        store.put(r.kind, value);
      } });
      return { restored: body.records.length, backup };
    }
    if (method === 'POST' && resource === 'ai') {
      const { analyze } = require('./career-codex.cjs');
      const job = body.jobID ? get('jobs', body.jobID) : null, m = body.materialID ? get('materials', body.materialID) : null;
      const target = get('profiles', body.profileID || store.list('profiles')[0].id);
      const input = { profile: target, job: job ? { id: job.id, title: job.title, company: job.company, description: job.description, requirements: job.requirements } : null, material: m ? { id: m.id, content: m.content } : null };
      const key = hash(input), cached = store.get('aiCache', key);
      if (cached) return cached;
      if (store.get('settings', 'ai')?.state === 'running') throw fail('模型分析正在进行', 409);
      store.put('settings', { id: 'ai', state: 'running', message: '正在使用本机 Codex 分析' });
      try {
        const result = await (options.analyze || analyze)(input);
        const row = { id: key, ...result, createdAt: now() };
        store.put('aiCache', row); store.put('settings', { id: 'ai', state: 'ok', lastSuccessAt: now(), message: '本机 Codex 已完成分析，规则结果仍保留。' }); return row;
      } catch (error) { store.put('settings', { id: 'ai', state: 'unavailable', message: error.message, checkedAt: now() }); throw fail(error.message, 503); }
    }
    throw fail('没有此求职助手接口', 404);
  }
  function tick() {
    const schedule = meta(), today = domain.day(now()), due = Date.parse(today + 'T09:00:00+08:00');
    if (!stopped && schedule.enabled && !active && Date.parse(now()) >= due && schedule.lastDay !== today) {
      const task = startRefresh();
      store.put('settings', { ...meta(), lastDay: today, taskID: task.id });
    }
  }
  function startScheduler() { if (timer) return; try { tick(); } catch {} timer = setInterval(() => { try { tick(); } catch {} }, 30000); timer.unref(); }
  async function close() { if (stopped) return; stopped = true; clearInterval(timer); active?.cancel?.(); await active?.promise; store.close(); }
  return { handle, snapshot, store, syncFeed, ingestNotes, startRefresh, tick, startScheduler, close, waitForTask: () => active?.promise || Promise.resolve() };
}
module.exports = { createCareerAssistant };
