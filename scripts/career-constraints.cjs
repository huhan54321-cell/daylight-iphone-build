'use strict';
// Literal extraction only; company introductions, dates and model guesses are not inputs.
function extractConstraints(value) {
  const clauses = String(value || '').normalize('NFKC').split(/[\n。！？!?;；，,]/).map(s => s.trim()).filter(Boolean);
  const soft = /优先|加分|可选|为主|不限|无要求|不要求|非必须|非强制|有则更好|最好/;
  const result = { minDays: null, minMonths: null, graduateYears: [], requiredDegree: null };
  const years = new Set(), evidence = [];
  for (const clause of clauses) {
    if (soft.test(clause)) continue;
    const days = /(?:每周|每星期|周)(?:\s*(?:至少|不少于|不低于|需(?:要)?|>=|≥))?\s*(\d(?:\.\d+)?)\s*(?:[-~至]\s*\d)?\s*天/.exec(clause);
    if (days) { const n = Number(days[1]); if (Number.isInteger(n) && n >= 1 && n <= 7) { result.minDays = Math.max(result.minDays || 0, n); evidence.push(clause); } }
    const months = /(?:至少|不少于|不低于|最短|最低|>=|≥|(?:连续)?实习(?:时长|时间|周期|期)?\s*[：:]?)\s*(\d{1,2})\s*(?:[-~至]\s*\d{1,2})?\s*(?:个)?月(?:以上|起)?/.exec(clause);
    if (months) { const n = Number(months[1]); if (Number.isInteger(n) && n >= 1 && n <= 24) { result.minMonths = Math.max(result.minMonths || 0, n); evidence.push(clause); } }
    const groups = [...clause.matchAll(/((?:20\d{2}\s*(?:[\/、或和]\s*)?)+)\s*届/g)];
    for (const group of groups) for (const match of group[1].matchAll(/20\d{2}/g)) { const year = Number(match[0]); if (year >= 2020 && year <= 2040) years.add(year); }
    if (groups.length) evidence.push(clause);
    let degree = null;
    if (/本科(?:及以上|或硕士|\/硕士)|(?:学历(?:要求)?\s*[：:]?\s*本科)/.test(clause)) degree = 'bachelor';
    else if (/硕士(?:及以上|或博士|\/博士)|(?:学历(?:要求)?\s*[：:]?\s*硕士)|硕士(?:学历|学位)/.test(clause)) degree = 'master';
    else if (/(?:仅限|只招)\s*(?:在读)?博士|学历(?:要求)?\s*[：:]\s*博士|^(?:\d+[.)、]\s*)?(?:须|必须|要求)\s*(?:拥有|具有|具备|持有)?\s*博士(?:学位|学历|研究生|在读)?|^博士(?:学位|学历)(?:及以上|或以上)?$|博士(?:研究生|在读)?(?:限定|仅限)/.test(clause)) degree = 'phd';
    if (degree) { const ranks = { bachelor: 1, master: 2, phd: 3 }; if (!result.requiredDegree || ranks[degree] > ranks[result.requiredDegree]) result.requiredDegree = degree; evidence.push(clause); }
  }
  result.graduateYears = [...years].sort(); result.evidence = [...new Set(evidence)].slice(0, 8);
  return result;
}
function applyConstraints(raw, actualJD) {
  const parsed = extractConstraints(actualJD);
  return { ...raw, minDays: raw.minDays ?? parsed.minDays, minMonths: raw.minMonths ?? parsed.minMonths, graduateYears: raw.graduateYears?.length ? raw.graduateYears : parsed.graduateYears,
    requiredDegree: raw.requiredDegree ?? parsed.requiredDegree,
    sourceNote: [raw.sourceNote || '', parsed.evidence.length ? '正文明确条件：' + parsed.evidence.join('；') : ''].filter(Boolean).join('\n').slice(0, 2000) };
}
module.exports = { extractConstraints, applyConstraints };
