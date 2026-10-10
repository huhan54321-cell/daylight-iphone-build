'use strict';
const test=require('node:test'), assert=require('node:assert/strict');
const api=require('../scripts/career-public-feed.cjs');
const now='2026-10-10T04:00:00Z';
test('new public scope excludes BOSS, Shixi and search pages before creating jobs',()=>{
  for(const url of ['https://www.zhipin.com/job_detail/a.html','https://www.shixiseng.com/intern/inn_a','https://careers.tencent.com/search.html'])
    assert.equal(api.jobFromSearch({url,title:'机器人算法实习',content:'杭州机器人实习'},now),null);
  assert.ok(!api.JOB_DOMAINS.some(h=>/zhipin|shixiseng/.test(h)));
});
test('official search retains uncertain city, does not infer JD from a search keyword',()=>{
  const j=api.jobFromSearch({url:'https://talent.alibaba.com/job/positionDetail.htm?positionId=123',title:'机器人算法实习生',content:'具身智能 Python 模仿学习'},now);
  assert.equal(j.company,'阿里巴巴');assert.equal(j.city,'城市待核查');assert.equal(j.verification,'listing_only');assert.equal(j.publishedAt,null);assert.equal(j.status,'unconfirmed');
});
test('source responsibilities and requirements retain internship constraints',()=>{
  const j=api.jobFromSearch({url:'https://talent.alibaba.com/job/positionDetail.htm?positionId=123',title:'机器人算法实习生',raw_content:'杭州 岗位职责：\n'+('具身操作与模仿学习训练，机器人仿真评测。'.repeat(10))+'\n任职要求：\n'+('熟悉 Python 与 PyTorch，每周至少4天，至少3个月。'.repeat(5))},now);
  assert.equal(j.verification,'full_jd');assert.equal(j.minDays,4);assert.equal(j.minMonths,3);assert.equal(j.city,'杭州');
});
test('news without a publication date stays undated rather than becoming today news',()=>{
  const article=api.articleFromSearch({url:'https://deepmind.google/discover/blog/robot-test/',title:'Embodied robot research',content:'Robot manipulation benchmarks and simulation.'},api.NEWS_PLANS[1],now);
  assert.equal(article.date,'');assert.equal(article.dateVerified,false);assert.equal(article.collectedAt,now);
  assert.ok(article.topics.includes('数据与评测'));
});
test('arXiv revisions preserve original date and unique base paper identity',()=>{
  const xml='<feed><entry><id>http://arxiv.org/abs/2610.00001v2</id><title>Robot manipulation policy</title><summary>Imitation learning with simulation benchmarks.</summary><published>2026-10-02T12:00:00Z</published><updated>2026-10-09T12:00:00Z</updated><author><name>Test Author</name></author></entry><entry><id>http://arxiv.org/abs/2610.00002v1</id><title>Robot paper</title><summary>Robot policy</summary><published>2026-10-12T12:00:00Z</published></entry></feed>';
  const rows=api.parseArxiv(xml,now);assert.equal(rows.length,1);assert.equal(rows[0].url,'https://arxiv.org/abs/2610.00001');assert.equal(rows[0].date,'2026-10-02T12:00:00.000Z');assert.deepEqual(rows[0].authors,['Test Author']);
  assert.equal(api.mergeArticles(rows,rows,now).length,1);
});
test('all API failures preserve existing jobs and articles without claiming success',async()=>{
  const j=api.jobFromSearch({url:'https://www.unitree.com/cn/position/123',title:'机器人算法实习生',content:'杭州 机器人'},now);
  const article={id:'prior',title:'Robot policy',url:'https://huggingface.co/blog/test-robot',date:'2026-10-08T00:00:00Z',summary:'Robot policy',category:'开源工具',relevance:''};
  const value=await api.collectPublicFeed({previous:{jobs:[j],articles:[article],sources:[]},key:'synthetic-key',fetchImpl:async()=>{throw Error('offline')},now});
  assert.equal(value.jobs.length,1);assert.equal(value.articles.length,1);assert.ok(value.sources.every(s=>s.state==='error'));assert.equal(value.updateInfo.jobsAttemptAt,null);assert.equal(value.scheduler.hostRequired,false);
});
test('job cadence avoids repeated paid searches and publication date uses China civil day',async()=>{
  const queries=[];
  const value=await api.collectPublicFeed({previous:{jobs:[],articles:[],sources:[],updateInfo:{jobsAttemptAt:'2026-10-09T12:00:00Z'}},now,key:'synthetic-key',fetchImpl:async(url,init)=>{if(String(url).includes('tavily'))queries.push(JSON.parse(init.body));return new Response(String(url).includes('tavily')?'{"results":[]}':'<feed/>') }});
  assert.equal(queries.length,6);assert.ok(queries.every(q=>q.topic==='news' && q.time_range==='week' && q.include_answer===false));assert.equal(value.updateInfo.searchRequests,6);assert.equal(api.dayKey('2026-10-09T16:30:00Z'),'2026-10-10');
});
