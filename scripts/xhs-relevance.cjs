'use strict';

// Explainable retrieval heuristics, not verification of an author's identity or claims.
// Search queries, comments, popularity and unrecognised image text are never evidence.
const VERSION = 1;
const SCOPE = 'algorithm_internship';
const CATEGORIES = { recruitment: '实习招聘', interview: '实习面经', experience: '实习经历分享', job_seeking: '求职求助', preparation: '备考与简历建议', other: '其他材料' };
const TIERS = { focus: '重点', supplement: '补充', review: '待核查', excluded: '范围外' };
const DOMAIN = /具身|\bVLA\b|\bVLN\b|机器人学习|robot\s*learning|embodied/i;
const ROBOT = /机器人|robot|机械臂|灵巧手|四足|人形|运控|运动控制|导航|SLAM/i;
const ALGORITHM = /算法|\bVLA\b|\bVLN\b|强化学习|模仿学习|机器人学习|运控|控制|规划|感知|导航|SLAM|模型|预训练|训练|仿真|sim.?to.?real|\bRL\b|\bIL\b/i;
const NON_ALGORITHM = /产品(?:经理|岗)|机械设计|硬件(?:开发|工程师|岗)|电气(?:工程师|岗)|运营|销售|标注员|测试岗|招聘专员|HR(?:招聘)?实习|人力资源|人事实习/i;
const INTERVIEW = /面经|面试|[一二三四五终]面|笔试|凉经/;
const EXPERIENCE = /心得|体验|经验分享|经历|总结|日常|入职|带教|实习.{0,12}(?:工作|周|月|结束|记录)|(?:找到|找到了|拿到|拿了).{0,20}(?:实习|offer)/i;
const SEEKER = /求捞|求助|求锐评|求建议|求内推|捞我|找(?:到|不到|个|一份|第一份|暑期|日常)?.{0,12}实习|投递实习|找工|求职|我的简历|简历如图|我.{0,8}投递/;
const RECRUIT = /招聘|招人|招募|招实习|急招|诚招|任职要求|岗位职责|岗位要求|职位要求|招聘要求|简历投递|投递(?:邮箱|方式)|内推机会|内推招聘/;
const PREP = /八股|指南|简历|学习路线|学习.{0,8}路线|项目推荐|备考|面试题|课程/;
function prose(value) { return String(value || '').slice(0, 20000).replace(/#[^\s#]+/g, ' ').replace(/https?:\/\/\S+/g, ' '); }
function classifyNote(note = {}, { stage = 'detail' } = {}) {
  const title = prose(note.title).replace(/^无标题帖子$/, ''), body = prose(note.text), all = title + '\n' + body;
  const reasons = [], flags = [];
  const directDomain = DOMAIN.test(all), robot = ROBOT.test(all), algorithm = ALGORITHM.test(all);
  const domain = directDomain || (robot && algorithm);
  const nonAlgorithm = NON_ALGORITHM.test(title) && !ALGORITHM.test(title);
  const titleIntern = /实习|intern(?:ship)?/i.test(title);
  const fulltime = !titleIntern && /秋招|春招|社招|全职|校招|专家|资深|高级工程师/.test(title);
  const internBody = /(?:招|招聘|岗位|职位).{0,24}实习|实习(?:生|岗位|招聘|一面|二面|面试)|(?:正在|这次|本次|这份|第一份|刚入职).{0,12}实习|实习.{0,12}(?:心得|结束|工作|经历|体验)/.test(body);
  const internship = titleIntern || (!fulltime && internBody);
  const seeker = SEEKER.test(title) || (!RECRUIT.test(title) && SEEKER.test(body));
  let category = /简历|八股指南|面试题汇总/.test(title) ? 'preparation' : INTERVIEW.test(title) && !/面试官视角/.test(title) ? 'interview' : EXPERIENCE.test(title) && !/求助|求捞|求建议/.test(title) ? 'experience' : seeker ? 'job_seeking' : RECRUIT.test(title) ? 'recruitment' : PREP.test(title) ? 'preparation' : RECRUIT.test(body) && !seeker ? 'recruitment' : INTERVIEW.test(body) ? 'interview' : EXPERIENCE.test(body) ? 'experience' : PREP.test(body) ? 'preparation' : 'other';
  // Guides containing question lists aren't necessarily an interview someone attended.
  if (/八股|指南|面试题汇总/.test(title) && !/记录|经历|经验分享/.test(title)) category = 'preparation';
  if (seeker && /求助|求捞|求锐评|求建议|简历如图/.test(title)) category = 'job_seeking';
  if (seeker && /怎么|如何|到底|怎样|怎么办|[？?]/.test(title)) category = 'job_seeking';
  if (!/实习|面经|面试|求职|招聘/.test(title) && /窗口期|融资|前景|技术路线|发展方向/.test(title)) category = 'other';
  const promotional = /陪跑|辅导|付费|咨询服务|购买课程|私信.{0,12}(?:课程|咨询|资料)|保offer|保过|学员|学生.{0,12}(?:面试|拿到|offer)/i.test(all);
  const closed = category === 'recruitment' && /已招满|已经招满|暂停招聘|停止招聘|招聘已结束|岗位已关闭|不再招|不招实习|实习.{0,8}(?:已截止|已结束)/.test(all);
  if (promotional) flags.push('含辅导或推广表述，经历来源待核实');
  if (fulltime) flags.push('标题指向校招、社招或全职，不能由过往实习经历认定为实习岗');
  if (closed) flags.push('正文出现招聘关闭或不招实习的表述');
  if (category === 'recruitment') flags.push('招聘方身份及岗位当前有效性未核验');
  if (body.trim().length < 25) flags.push('正文信息少，需核查原帖或图片');
  if (!algorithm && directDomain) flags.push('算法方向未明确，需核查岗位内容');
  let tier = 'excluded';
  if (domain && !nonAlgorithm) {
    reasons.push(directDomain ? '标题或正文含具身/VLA/VLN方向' : '标题或正文同时含机器人场景与算法方向');
    reasons.push(internship ? '有当前实习语境' : '实习岗位语境未确认');
    tier = internship && ['recruitment', 'interview', 'experience'].includes(category) ? 'focus' : 'supplement';
    if (category === 'other') tier = 'excluded';
    if (promotional || closed || fulltime) tier = tier === 'excluded' ? tier : 'supplement';
  } else reasons.push(nonAlgorithm ? '标题明确为其他职能岗位' : '标题与正文缺少具身算法相关证据');
  if (stage === 'detail' && !domain && !nonAlgorithm && titleIntern && (!body.trim() || body.trim().length < 25 && /如图|见图|图片|简历/.test(all) || DOMAIN.test(String(note.text || '')))) {
    tier = 'review'; flags.push('仅有实习标题或领域标签，具身算法相关性待核查');
  }
  // Search cards are incomplete. Keep a small exploration budget for ambiguous titles.
  if (stage === 'card' && tier === 'excluded' && !nonAlgorithm && (!title.trim() || /实习|面经|[一二三]面/.test(title) || domain && category === 'other' && !/融资|前景|窗口期|技术路线|学习路线/.test(title))) tier = 'review';
  let score = { focus: 75, supplement: 35, review: 10, excluded: 0 }[tier];
  if (tier !== 'excluded') score += (titleIntern ? 8 : 0) + (DOMAIN.test(title) ? 5 : 0) + (algorithm ? 4 : 0) + (body.trim().length >= 120 ? 3 : 0) - (promotional ? 12 : 0) - (closed ? 15 : 0);
  return { version: VERSION, category, label: CATEGORIES[category], tier, tierLabel: TIERS[tier], score, internship, reasons, flags };
}
function rankNotes(notes) { return notes.map(note => ({ ...note, relevance: classifyNote(note) })).sort((a, b) => b.relevance.score - a.relevance.score || String(a.id).localeCompare(String(b.id))); }
function summarize(notes) {
  const counts = { focus: 0, supplement: 0, review: 0, excluded: 0, categories: {} };
  for (const note of notes) { const r = classifyNote(note); counts[r.tier]++; counts.categories[r.label] = (counts.categories[r.label] || 0) + 1; }
  return counts;
}
function planCandidates(candidates, maxNotes) {
  const ranked = candidates.map(card => ({ ...card, relevance: classifyNote(card, { stage: 'card' }) })).sort((a, b) => b.relevance.score - a.relevance.score);
  const primary = ['recruitment', 'interview', 'experience'].map(category => ranked.filter(c => c.relevance.tier === 'focus' && c.relevance.category === category));
  const ordered = [];
  // Spread the main budget across three intents; a popular query cannot consume it all.
  while (primary.some(pool => pool.length) && ordered.length < maxNotes) for (const pool of primary) if (pool.length && ordered.length < maxNotes) ordered.push(pool.shift());
  const supplementLimit = Math.floor(maxNotes * 0.2), reviewLimit = Math.max(1, Math.floor(maxNotes * 0.1));
  for (const [tier, limit] of [['supplement', supplementLimit], ['review', reviewLimit]]) {
    ordered.push(...ranked.filter(c => c.relevance.tier === tier).slice(0, Math.min(limit, maxNotes - ordered.length)));
  }
  return ordered;
}
function detailDecision(raw, config) {
  if (config.researchScope !== SCOPE) return { collectExtras: true, reason: '' };
  const relevance = classifyNote(raw);
  const dated = ['exact', 'relative'].includes(raw.dateEvidence) && raw.publishedDate;
  const outside = dated && (raw.publishedDate < config.startDate || raw.publishedDate > config.endDate);
  const collectExtras = relevance.tier !== 'excluded' && !outside;
  return { collectExtras, relevance, reason: outside ? '发布日期明确超出当前范围' : !collectExtras ? relevance.reasons.join('；') : '' };
}
module.exports = { VERSION, SCOPE, CATEGORIES, TIERS, classifyNote, rankNotes, summarize, planCandidates, detailDecision };
