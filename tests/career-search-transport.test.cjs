'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {PassThrough}=require('node:stream');
const {createSearchFetch}=require('../scripts/career-search-transport.cjs');

function fakeChild(){const child=new EventEmitter();child.stdin=new PassThrough();child.stdout=new PassThrough();child.kill=()=>{child.killed=true;};return child;}

test('Windows search credentials use stdin only and response returns through bounded fetch-compatible API', async()=>{
  let invocation,payload;
  const fetch=createSearchFetch(()=>{throw new Error('wrong transport');},{CAREER_TAVILY_TRANSPORT:'windows',HTTPS_PROXY:'http://127.0.0.1:7897'},{platform:'win32',spawn:(command,args,options)=>{
    invocation={command,args,options};const child=fakeChild();let input='';child.stdin.on('data',b=>input+=b.toString());
    queueMicrotask(()=>{payload=JSON.parse(input);child.stdout.write(JSON.stringify({status:200,body:'{"results":[]}'}));child.emit('close',0);});return child;
  }});
  const response=await fetch('https://api.tavily.com/search',{method:'POST',headers:{Authorization:'Bearer unit-test-secret'},body:'{"query":"杭州机器人"}'});
  assert.equal(response.status,200);assert.deepEqual(await response.json(),{results:[]});
  assert.equal(payload.authorization,'Bearer unit-test-secret');
  assert.equal(payload.proxy,'http://127.0.0.1:7897');
  assert.equal(JSON.stringify(invocation).includes('unit-test-secret'),false);
  assert.equal(invocation.options.shell,false);assert.equal(invocation.options.windowsHide,true);
});

test('transport is limited to configured Windows Tavily search and leaves other sources with their original fetch', async()=>{
  let calls=0;const base=async()=>{calls++;return new Response('{}');};
  const fetch=createSearchFetch(base,{CAREER_TAVILY_TRANSPORT:'windows'},{platform:'win32',spawn:()=>{throw new Error('must not spawn');}});
  await fetch('https://www.unitree.com/cn/position/');
  await createSearchFetch(base,{}, {platform:'win32'})('https://api.tavily.com/search');
  await createSearchFetch(base,{CAREER_TAVILY_TRANSPORT:'windows'}, {platform:'linux'})('https://api.tavily.com/search');
  assert.equal(calls,3);
});

test('outer request cancellation terminates the helper without persisting credentials', async()=>{
  let child;const controller=new AbortController();
  const fetch=createSearchFetch(()=>{}, {CAREER_TAVILY_TRANSPORT:'windows'}, {platform:'win32',spawn:()=>child=fakeChild()});
  const promise=fetch('https://api.tavily.com/search',{signal:controller.signal,headers:{Authorization:'Bearer test'},body:'{}'});
  controller.abort();await assert.rejects(promise,{name:'AbortError'});assert.equal(child.killed,true);
});
