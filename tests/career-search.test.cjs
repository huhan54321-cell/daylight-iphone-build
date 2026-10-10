'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { collectTavily, SourceError } = require('../scripts/career-adapters.cjs');

test('search uses current Bearer authentication and fixes basic search cost without sending credentials in body', async () => {
  const calls=[];
  const result=await collectTavily(async (url, options, hosts) => {
    calls.push({url,options,hosts});
    return JSON.stringify({results:[{title:'杭州机器人算法实习生招聘',url:'https://www.zhipin.com/job_detail/abc123.html',content:'杭州 具身智能机器人算法实习，具体资格请查看原文'}]});
  }, {TAVILY_API_KEY:'tvly-local-test',CAREER_QUERIES:[{city:'杭州',keyword:'具身智能'}]});
  assert.equal(calls.length,1);
  assert.equal(calls[0].options.headers.Authorization,'Bearer tvly-local-test');
  const body=JSON.parse(calls[0].options.body);
  assert.equal(body.api_key,undefined);
  assert.equal(body.search_depth,'basic');
  assert.equal(body.auto_parameters,false);
  assert.equal(body.include_answer,false);
  assert.equal(body.include_domains_mode,'restrict');
  assert.equal(result.jobs[0].company,'公司待核查');
  assert.equal(result.jobs[0].verification,'listing_only');
  assert.deepEqual(result.jobs[0].requirements,[]);
  assert.equal(result.jobs[0].status,'unconfirmed');
});

test('missing search credentials never perform a request or claim live collection', async () => {
  const result=await collectTavily(()=>{throw new Error('must not request');},{});
  assert.equal(result.state,'not_configured');
  assert.deepEqual(result.jobs,[]);
});

test('search rejects BOSS category pages but keeps relevant university postings with generic titles as unverified clues', async () => {
  const result=await collectTavily(async()=>JSON.stringify({results:[
    {title:'杭州宇树科技招聘信息',url:'https://www.zhipin.com/zhaopin/category',content:'具身智能算法实习 北京 杭州招聘'},
    {title:'浙江大学就业服务平台',url:'https://www.career.zju.edu.cn/jyxt/sczp/zpztgl/ckZpgwXq.zf?zpxxbh=posting123',content:'具身智能算法实习 岗位职责：机器人开发'},
    {title:'杭州具身智能岗位',url:'https://www.zhipin.com/web/geek/jobs?query=robot',content:'招聘实习生'}
  ]}),{TAVILY_API_KEY:'tvly-local-test',CAREER_QUERIES:[{city:'杭州',keyword:'具身智能'}]});
  assert.equal(result.jobs.length,1);
  assert.equal(result.jobs[0].title,'浙江大学就业服务平台');
  assert.equal(result.jobs[0].company,'公司待核查');
  assert.equal(result.jobs[0].jobType,'类型未注明');
  assert.equal(result.jobs[0].verification,'listing_only');
});

test('later search failure retains earlier results and reports only completed queries', async () => {
  let calls=0;
  const result=await collectTavily(async()=>{
    if(++calls===2) throw new SourceError('error','来源请求超时');
    return JSON.stringify({results:[{title:'杭州机器人算法实习生招聘',url:'https://www.zhipin.com/job_detail/abc123.html',content:'具身智能机器人实习'}]});
  },{TAVILY_API_KEY:'tvly-local-test',CAREER_QUERIES:[{city:'杭州',keyword:'具身智能'},{city:'杭州',keyword:'群核科技'},{city:'上海',keyword:'机器人'}]});
  assert.equal(calls,2);
  assert.equal(result.state,'error');
  assert.equal(result.jobs.length,1);
  assert.equal(result.coverage.queriesRun,1);
  assert.equal(result.coverage.pagesRun,1);
  assert.match(result.message,/1\/3/);
});
