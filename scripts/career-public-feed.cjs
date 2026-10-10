'use strict';
// Shared public information only. Never read a resume, browser session or device data.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { normalizeJob, mergeJobs, safeURL, dateISO } = require('./career-core.cjs');
const { plain, decodeEntities } = require('./career-adapters.cjs');
const { applyConstraints } = require('./career-constraints.cjs');

const OMITTED = /(?:^|\.)(?:zhipin|shixiseng)\.com$/;
const EMPLOYERS = {
  'talent.alibaba.com': '阿里巴巴', 'careers.tencent.com': '腾讯', 'hr.163.com': '网易',
  'career.huawei.com': '华为', 'jobs.bytedance.com': '字节跳动', 'talent.baidu.com': '百度',
  'hr.xiaomi.com': '小米', 'zhaopin.meituan.com': '美团', 'we.dji.com': '大疆',
  'job.hikrobotics.com': '海康机器人', 'join.hikvision.com': '海康威视',
  'www.unitree.com': '宇树科技', 'unitree.com': '宇树科技',
  'www.deeprobotics.cn': '云深处科技', 'www.wlrobo.com': '万龙机器人', 'wlrobo.com': '万龙机器人',
  'www.linx-robot.com': '灵西机器人', 'www.westlakedi.com': '西湖机器人'
};
const JOB_DOMAINS = [...Object.keys(EMPLOYERS), 'www.zhaopin.com', 'jobs.zhaopin.com', 'www.nowcoder.com', 'www.career.zju.edu.cn'];
const JOB_QUERIES = [
  '杭州 具身智能 机器人 操作学习 算法 实习 招聘', '杭州 机器人仿真 MuJoCo 模仿学习 实习 招聘',
  '阿里巴巴 达摩院 机器人 具身智能 实习 招聘', '腾讯 Robotics X 机器人 具身智能 实习 招聘',
  '网易 机器人 具身智能 杭州 实习 招聘', '华为 具身智能 机器人 算法 实习 招聘',
  '海康机器人 海康威视 杭州 机器人 算法 实习 招聘', '宇树 云深处 杭州 机器人 算法 实习 招聘',
  '群核科技 灵西 西湖机器人 万龙 杭州 具身智能 实习 招聘',
  '大疆 小米 美团 机器人 算法 实习 招聘', '字节跳动 百度 具身智能 VLA 机器人 实习 招聘',
  '上海 北京 深圳 机器人 具身操作 仿真算法 实习 牛客 智联 招聘'
];
const NEWS_PLANS = [
  { category: '行业动态', query: '具身智能 人形机器人 新产品 产业进展 融资 本周', domains: ['unitree.com','deeprobotics.cn','agibot.com','galbot.com','figure.ai','1x.tech','36kr.com','jiqizhixin.com'] },
  { category: '技术进展', query: 'robotics embodied AI vision language action model new research', domains: ['deepmind.google','research.google','pi.website','nvidia.com','bair.berkeley.edu','research.nvidia.com'] },
  { category: '操作与学习', query: 'robot manipulation imitation reinforcement learning dexterous latest', domains: ['robotics-transformer-x.github.io','huggingface.co','bair.berkeley.edu','deepmind.google','arxiv.org'] },
  { category: '仿真与评测', query: 'robotics simulation sim2real world model benchmark dataset new release', domains: ['developer.nvidia.com','nvidia.com','huggingface.co','research.google','mujoco.org','arxiv.org'] },
  { category: '开源工具', query: 'LeRobot robotics open source policy dataset framework release', domains: ['huggingface.co','github.com','developer.nvidia.com','mujoco.org'] },
  { category: '硬件与落地', query: 'humanoid robotics dexterous hand deployment manufacturing robot new', domains: ['figure.ai','unitree.com','agibot.com','1x.tech','nvidia.com','deepmind.google'] }
];
const THEMES = [
  ['VLA 与动作模型', /vision.language.action|\bVLA\b|action model/i],
  ['操作与灵巧手', /manipulation|dexter|grasp|操作|灵巧|抓取/i],
  ['模仿学习', /imitation|behavior.clon|模仿学习/i], ['强化学习', /reinforcement|强化学习/i],
  ['仿真与迁移', /sim2real|sim.to.real|simulation|仿真|迁移/i],
  ['世界模型', /world.model|世界模型/i], ['数据与评测', /dataset|benchmark|evaluation|数据集|评测/i],
  ['运动控制', /locomotion|whole.body|运动控制|全身控制/i]
];
const relevant = s => /robot|embodied|manipulation|dexter|grasp|具身|机器人|灵巧手|机械臂|LeRobot|MuJoCo/i.test(s);
const digest = s => crypto.createHash('sha256').update(s).digest('hex').slice(0,24);
const dayKey = date => new Intl.DateTimeFormat('en-CA', { timeZone:'Asia/Shanghai', year:'numeric',month:'2-digit',day:'2-digit' }).format(new Date(date));
function publicURL(value) {
  try { const u = new URL(value); if (u.protocol !== 'https:' || u.username || u.password || u.port || OMITTED.test(u.hostname)) return null;
    for (const key of [...u.searchParams.keys()]) if (/^utm_|^spm$/i.test(key)) u.searchParams.delete(key);
    return u.href;
  } catch { return null; }
}
function postingURL(value) {
  const u = new URL(value), rest = u.pathname + u.search + u.hash;
  return /\/jobdetail\/|\/CC\w+\.htm|\/jobs\/detail\/\d+|zpxxbh=|\/position\/\d+|(?:position|job|post|requisition)[-_]?(?:id|detail)[=\/]|\/jobs\/\d+|\/careers?\/[^/]+\/[^/]+/i.test(rest);
}
function sourceID(url) {
  const host = new URL(url).hostname;
  if (host.includes('zhaopin.com')) return 'zhaopin';
  if (host.includes('nowcoder.com')) return 'nowcoder';
  if (host.includes('career.zju.edu.cn')) return 'zju';
  return 'official';
}
function jobFromSearch(row, now) {
  const url = publicURL(row.url); if (!url || !postingURL(url)) return null;
  const title = plain(row.title || '').slice(0,180), body = plain(row.raw_content || row.content || '').slice(0,12000);
  if (!relevant(title + body) || !/实习|internship|intern\b/i.test(title + body)) return null;
  const host = new URL(url).hostname;
  const company = EMPLOYERS[host] || /_([^_]+?)(?:实习|校招|社招)_牛客/.exec(title)?.[1] || /招聘_([^_]+?)招聘\s*[-_]/.exec(title)?.[1] || /(?:公司名称|招聘单位|公司)[：:]\s*([^\n]{2,50})/.exec(body)?.[1] || '公司待核查';
  const city = /杭州|上海|北京|深圳|苏州|广州|南京|成都|武汉/.exec(body + ' ' + title)?.[0] || '城市待核查';
  // Search extracts are incomplete; only source sections establish responsibilities/requirements.
  const duties = /(?:岗位职责|职位描述|工作职责|Responsibilities)[：:\s]*([\s\S]+?)(?=任职要求|职位要求|岗位要求|Qualifications|Requirements|$)/i.exec(body)?.[1]?.trim();
  const requirements = /(?:任职要求|职位要求|岗位要求|Qualifications|Requirements)[：:\s]*([\s\S]+)/i.exec(body)?.[1]?.trim();
  const full = Boolean(duties?.length >= 80 && requirements?.length >= 60 && company !== '公司待核查');
  try { return normalizeJob(applyConstraints({ title, company, city, jobType: /实习|intern\b/i.test(title) || /(?:职位类型|岗位类型|工作性质|Employment Type)[：:\s]*(?:实习|intern)/i.test(body) ? '实习' : '类型未注明',
    url, description: (duties || body).slice(0,3200), requirements: requirements ? requirements.split('\n').filter(Boolean).slice(0,20) : [],
    publishedAt: row.published_date || null, status:'unconfirmed', verification:full ? 'full_jd' : 'listing_only',
    sourceNote:full ? '来自公开来源的职责和要求摘录；请以原始招聘页确认名额与完整条件。' : '公开搜索摘要，尚未取得完整 JD；不表示目前可投递。',
    tags: THEMES.filter(([,pattern])=>pattern.test(title+body)).map(([name])=>name), relatedURLs:[] }, body), sourceID(url), now); } catch { return null; }
}
function articleFromSearch(row, plan, now) {
  const url = publicURL(row.url); if (!url) return null;
  const title = plain(row.title || '').slice(0,400), content = plain(row.content || row.raw_content || '');
  if (!title || !relevant(title + content) || /招聘|招募|实习岗位/.test(title)) return null;
  const host = new URL(url).hostname;
  // Papers use the dedicated bibliographic API, not search-index timestamps.
  if (host === 'arxiv.org' || host.endsWith('.arxiv.org')) return null;
  if (!relevant(title) && !(/3DGS|digital.twin|sim.to.real|sim2real|3D reconstruction/i.test(title) && relevant(content))) return null;
  if (host === 'github.com' && !/^https:\/\/github.com\/(?:huggingface\/lerobot|nvidia\/isaac-gr00t|isaac-sim\/isaaclab|google-deepmind\/mujoco|physical-intelligence\/openpi)(?:\/|$)/i.test(url)) return null;
  if (!plan.domains.some(domain => host === domain || host.endsWith('.'+domain))) return null;
  // Never substitute collection time for publication time.
  const date = host === 'github.com' && !url.includes('/releases/tag/') ? null : dateISO(row.published_date) || dateISO(/(?:发布时间|发布日期|Published|Date)[：:\s]+(20\d{2}-\d{2}-\d{2})/i.exec(content)?.[1]);
  if (date && Date.parse(date) > Date.parse(now) + 86400000) return null;
  return { id:'article-'+digest(url), title, date:date || '', category:plan.category,
    summary:content.slice(0,900), relevance:'', url, sourceName:host, authors:[],
    topics:THEMES.filter(([,p])=>p.test(title+' '+content)).map(([n])=>n),
    highlights:content.split(/(?<=[。.!?])\s+/).filter(s=>relevant(s)).slice(0,3).map(s=>s.slice(0,220)),
    collectedAt:now, dateVerified:Boolean(date), updatedAt:null, kind:'news' };
}
function xmlField(xml, name) { return decodeEntities(new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)<\\/${name}>`, 'i').exec(xml)?.[1] || '').replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g,'$1').trim(); }
function parseArxiv(xml, now) {
  return [...xml.matchAll(/<entry\b[^>]*>([\s\S]*?)<\/entry>/gi)].flatMap(([,entry])=> {
    const raw = xmlField(entry,'id').replace(/^http:/,'https:');
    if (!/^https:\/\/arxiv.org\/abs\/(?:\d{4}\.\d{4,5}|[a-z-]+\/\d{7})(?:v\d+)?$/.test(raw)) return [];
    const url = raw.replace(/v\d+$/,''), title=plain(xmlField(entry,'title')), summary=plain(xmlField(entry,'summary'));
    if (!relevant(title+' '+summary)) return [];
    const date=dateISO(xmlField(entry,'published')), updated=dateISO(xmlField(entry,'updated'));
    if (!date || Date.parse(date) > Date.parse(now) || Date.parse(date) < Date.parse(now)-45*86400000) return [];
    return [{id:'paper-'+digest(url), title, date, category:'论文', summary:summary.slice(0,1000), relevance:'', url,
      sourceName:'arXiv · 预印本', authors:[...entry.matchAll(/<author\b[^>]*>([\s\S]*?)<\/author>/gi)].map(([,a])=>xmlField(a,'name')).slice(0,20),
      topics:THEMES.filter(([,p])=>p.test(title+' '+summary)).map(([n])=>n), highlights:[], collectedAt:now,
      dateVerified:true, updatedAt:updated, kind:'paper'}];
  });
}
function parseHuggingFace(xml, now) {
  return [...xml.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)].flatMap(([,item])=> {
    const row={title:xmlField(item,'title'),url:xmlField(item,'link'),content:plain(xmlField(item,'description')),published_date:xmlField(item,'pubDate')};
    const value=articleFromSearch(row,{category:'开源工具',domains:['huggingface.co']},now);
    return value && value.date && Date.parse(value.date) >= Date.parse(now)-45*86400000 ? [value] : [];
  });
}
function mergeArticles(previous, incoming, now) {
  const rows=new Map();
  for (const row of [...previous,...incoming]) {
    const url=publicURL(row.url); if (!url) continue;
    if (row.date && (Date.parse(row.date)<Date.parse(now)-45*86400000 || Date.parse(row.date)>Date.parse(now)+86400000)) continue;
    const prior=rows.get(url); if (!prior || !prior.date || row.date) rows.set(url,{...row,url});
  }
  return [...rows.values()].sort((a,b)=>String(b.date).localeCompare(String(a.date))).slice(0,100);
}
async function collectPublicFeed({ previous, now=new Date().toISOString(), fetchImpl=global.fetch, key='', forceJobs=false, jobsOnly=false }) {
  const states=[], jobs=[], articles=[]; let calls=0;
  async function fetchText(url, init={}) {
    const r=await fetchImpl(url,{...init,signal:AbortSignal.timeout(35000)});
    if (!r.ok) throw new Error('HTTP '+r.status);
    const value=await r.text(); if (Buffer.byteLength(value)>4_194_304) throw new Error('Response too large'); return value;
  }
  async function search(query, domains, news=false) {
    if (!key) throw new Error('Search credential missing'); calls++;
    return JSON.parse(await fetchText('https://api.tavily.com/search',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},
      body:JSON.stringify({query,search_depth:'basic',auto_parameters:false,include_answer:false,max_results:10,
        include_raw_content:news ? false : 'text',include_domains:domains,exclude_domains:['zhipin.com','shixiseng.com'],
        ...(news ? {topic:'news',time_range:'week'} : {topic:'general'})})})).results || [];
  }
  async function attempt(id,name,fn) {
    const prior=(previous.sources||[]).find(s=>s.id===id); let count=0, ok=false;
    try { count=await fn(); ok=true; } catch { /* Keep previous content and expose partial failures. */ }
    states.push({id,name,state:ok?'ok':'error',lastAttemptAt:now,lastSuccessAt:ok?now:prior?.lastSuccessAt||null,count,
      message:ok ? `本轮读取 ${count} 条公开记录；原页日期与核查状态分别保留。` : '来源请求未完成，保留已有记录；下次定时任务重试。'});
  }
  const lastJobs=previous.updateInfo?.jobsAttemptAt;
  const jobDue=forceJobs || !lastJobs || Date.parse(now)-Date.parse(lastJobs)>=72*3600000;
  if(jobDue) await attempt('public-jobs','企业官网与公开招聘',async()=>{
    let completed=0;
    for(const query of JOB_QUERIES) {
      try { const rows=await search(query,JOB_DOMAINS); completed++; for(const row of rows) { const value=jobFromSearch(row,now); if(value)jobs.push(value); } }
      catch { continue; }
    }
    if (!completed) throw new Error('No source succeeded');
    if(completed!==JOB_QUERIES.length) states.push({id:'job-coverage',name:'岗位覆盖进度',state:'error',lastAttemptAt:now,lastSuccessAt:null,count:completed,message:`已完成 ${completed}/${JOB_QUERIES.length} 组查询，部分来源失败；现有岗位保留。`});
    return jobs.length;
  });
  else states.push(...(previous.sources||[]).filter(s=>['public-jobs','job-coverage'].includes(s.id)));
  if(!jobsOnly) {
    for(const plan of NEWS_PLANS) await attempt('news-'+digest(plan.category),plan.category,async()=>{
      const rows=await search(plan.query,plan.domains,true); const found=rows.map(r=>articleFromSearch(r,plan,now)).filter(Boolean);articles.push(...found);return found.length;
    });
    await attempt('arxiv','arXiv 论文',async()=>{
      const query='cat:cs.RO AND (all:manipulation OR all:embodied OR all:humanoid OR all:imitation OR all:reinforcement OR all:sim2real)';
      const url='https://export.arxiv.org/api/query?'+new URLSearchParams({search_query:query,max_results:'40',sortBy:'submittedDate',sortOrder:'descending'});
      const values=parseArxiv(await fetchText(url,{headers:{'User-Agent':'DaylightPublicResearch/1.0'}}),now);articles.push(...values);return values.length;
    });
    await attempt('huggingface','Hugging Face 开源进展',async()=>{const values=parseHuggingFace(await fetchText('https://huggingface.co/blog/feed.xml'),now);articles.push(...values);return values.length;});
  }
  const kept=(previous.jobs||[]).filter(j=>!['boss','shixiseng','shixiseng-public'].includes(j.sourceID) && publicURL(j.url));
  const jobsOK=states.find(s=>s.id==='public-jobs')?.state==='ok' && !states.some(s=>s.id==='job-coverage');
  return {schemaVersion:1,generatedAt:now,jobs:mergeJobs(kept,jobs).slice(0,800),sources:states,
    articles:mergeArticles(previous.articles||[],articles,now),
    updateInfo:{jobsAttemptAt:jobDue&&jobsOK?now:lastJobs||null,newsAttemptAt:jobsOnly?previous.updateInfo?.newsAttemptAt||null:now,
      schedule:'资讯每日更新，岗位每三天更新；手动刷新读取最新已发布内容。',searchRequests:calls},
    scheduler:{enabled:true,intervalHours:72,nextRunAt:new Date(Date.parse(jobDue&&jobsOK?now:lastJobs||now)+72*3600000).toISOString(),lastRunAt:now,lastFinishedAt:now,budgetDay:dayKey(now),budgetUsed:calls,budgetLimit:18,hostRequired:false,running:false}};
}
if(require.main===module) (async()=>{
  const destination=path.resolve(process.argv[2]||'public/career-feed.json');
  const prior=fs.existsSync(destination)?JSON.parse(fs.readFileSync(destination,'utf8')):{jobs:[],articles:[],sources:[]};
  const {createSearchFetch}=require('./career-search-transport.cjs');
  const feed=await collectPublicFeed({previous:prior,key:process.env.TAVILY_API_KEY||'',fetchImpl:createSearchFetch(),forceJobs:process.argv.includes('--force-jobs')});
  fs.mkdirSync(path.dirname(destination),{recursive:true});fs.writeFileSync(destination,JSON.stringify(feed,null,2)+'\n');
  console.log(JSON.stringify({jobs:feed.jobs.length,articles:feed.articles.length,searchRequests:feed.updateInfo.searchRequests,sources:feed.sources.map(s=>({id:s.id,state:s.state,count:s.count}))}));
})().catch(()=>{console.error('Public update failed; previous published file is retained.');process.exitCode=1;});
module.exports={EMPLOYERS,JOB_DOMAINS,JOB_QUERIES,NEWS_PLANS,jobFromSearch,articleFromSearch,parseArxiv,parseHuggingFace,mergeArticles,collectPublicFeed,dayKey,postingURL};
