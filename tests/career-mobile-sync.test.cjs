'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createCareerAssistant } = require('../scripts/career-assistant.cjs');
const { normalizeJob, initialFeed } = require('../scripts/career-core.cjs');
const stamp = '2026-10-19T02:00:00Z';
async function setup(t) {
  fs.mkdirSync('.test-tmp', { recursive: true });
  const dataDir = fs.mkdtempSync(path.resolve('.test-tmp/mobile-'));
  const job = normalizeJob({ company: '测试机器人团队', title: '机器人实习', city: '杭州', url: 'https://www.unitree.com/cn/position/1234', description: '完整机器人招聘正文。', verification: 'full_jd' }, 'unitree', stamp);
  const a = createCareerAssistant({ dataDir, getFeed: () => initialFeed(), now: () => stamp });
  a.syncFeed({ jobs: [job] });
  t.after(async () => { await a.close(); fs.rmSync(dataDir, { recursive: true, force: true }); });
  const sync = async (...operations) => (await a.handle('POST', '/v2/career/sync', { operations })).results;
  return { a, job, sync };
}
test('offline edits preserve unrelated desktop updates, retries are idempotent regardless of JSON key order', async t => {
  const {a,job,sync}=await setup(t);
  await a.handle('POST', `/v2/career/jobs/${job.id}/followup`, {stage:'已投递',notes:'电脑笔记'});
  const op={id:'operation-001',kind:'followups',targetID:job.id,base:{saved:false},patch:{saved:true}};
  let [r]=await sync(op);assert.equal(r.state,'applied');assert.equal(r.current.stage,'已投递');assert.equal(r.current.notes,'电脑笔记');
  const again=await sync({patch:{saved:true},base:{saved:false},targetID:job.id,kind:'followups',id:'operation-001'});
  assert.deepEqual(again[0],r);assert.equal(a.store.get('followups',job.id).revision,2);
  [r]=await sync({...op,patch:{saved:false}});assert.equal(r.state,'error');assert.match(r.message,/编号已使用/);
  await a.handle('POST', `/v2/career/jobs/${job.id}/followup`, {saved:false});assert.equal(a.store.get('followups',job.id).stage,'已投递');
});
test('concurrent stage changes conflict without overwriting; explicit rebased resolution succeeds',async t=>{
  const {a,job,sync}=await setup(t);await a.handle('POST',`/v2/career/jobs/${job.id}/followup`,{stage:'已投递'});
  const op={id:'operation-conflict',kind:'followups',targetID:job.id,base:{stage:'未投递'},patch:{stage:'面试'}};
  const [r]=await sync(op);assert.equal(r.state,'conflict');assert.deepEqual(r.fields,['stage']);assert.equal(a.store.get('followups',job.id).stage,'已投递');
  const [resolved]=await sync({...op,id:'operation-resolved',base:{stage:r.current.stage}});assert.equal(resolved.state,'applied');assert.equal(resolved.current.stage,'面试');
});
test('invalid operations cannot submit applications and do not block other records; interview cancellation persists',async t=>{
  const {a,job,sync}=await setup(t);
  const [bad,good]=await sync({id:'operation-bad',kind:'applications',targetID:'any',base:{},patch:{state:'approved'}},{id:'operation-good',kind:'followups',targetID:job.id,base:{interview:null},patch:{interview:{start:'2026-10-20T03:00:00Z',end:'2026-10-20T04:00:00Z',location:'在线'}}});
  assert.equal(bad.state,'error');assert.equal(good.state,'applied');assert.equal(a.store.list('applications').length,0);
  await assert.rejects(a.handle('POST',`/v2/career/jobs/${job.id}/followup`,{interview:{start:stamp,end:stamp}}),/起止时间/);
  await a.handle('POST',`/v2/career/jobs/${job.id}/followup`,{interview:null});assert.equal(a.store.get('followups',job.id).interview,null);
});
test('old phone favourites import original source dates and preserve complete desktop JD',async t=>{
  const {a,job,sync}=await setup(t);
  const [r]=await sync({id:'operation-legacy',kind:'followups',targetID:'legacy-swift-id',job:{...job,description:'摘要',verification:'listing_only'},base:{saved:false},patch:{saved:true}});
  assert.equal(r.state,'applied');assert.equal(r.targetID,job.id);assert.equal(a.snapshot().jobs.length,1);assert.equal(a.snapshot().jobs[0].description,job.description);assert.equal(Date.parse(a.snapshot().jobs[0].checkedAt),Date.parse(stamp));
});
test('review returns immutable PDF version; requesting changes invalidates an already approved hash',async t=>{
  const {a,job}=await setup(t);const m=await a.handle('POST','/v2/career/materials',{title:'真实经历',content:'测试项目经历',confirmedFacts:true,attachment:{name:'test.pdf',base64:Buffer.from('%PDF-1.7\nTEST').toString('base64')}});
  const app=await a.handle('POST','/v2/career/applications',{jobID:job.id,materialID:m.id,action:'submit',fields:{}});
  await a.handle('POST',`/v2/career/applications/${app.id}/approve`,{reviewHash:app.reviewHash,confirmed:true});
  const updated=await a.handle('POST',`/v2/career/applications/${app.id}/request-changes`,{reviewHash:app.reviewHash,note:'补充项目日期'});assert.equal(updated.state,'draft');assert.notEqual(updated.reviewHash,app.reviewHash);
  await assert.rejects(a.handle('POST',`/v2/career/applications/${app.id}/approve`,{reviewHash:app.reviewHash,confirmed:true}),/变化/);
  await a.handle('POST','/v2/career/materials',{id:m.id,title:m.title,content:'更新项目',confirmedFacts:true,attachment:null});
  const review=await a.handle('GET',`/v2/career/applications/${app.id}/review`);assert.equal(review.valid,false);assert.equal(review.material.version,1);assert.ok(review.material.attachment.base64);
});
