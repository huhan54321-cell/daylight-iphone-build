'use strict';
const relevance = require('./xhs-relevance.cjs');

const MAX_KNOWN_IDS = 100000;
function normalizeKnownNoteIds(input = []) {
  if (!Array.isArray(input) || input.length > MAX_KNOWN_IDS) throw new Error(`已入库帖子 ID 须为不超过 ${MAX_KNOWN_IDS} 条的列表。`);
  const ids = new Set();
  for (const value of input) {
    if (typeof value !== 'string' || !/^[a-f\d]{24}$/i.test(value)) throw new Error('已入库帖子 ID 须为 24 位十六进制字符串。');
    ids.add(value.toLowerCase());
  }
  return [...ids];
}
function noteID(value) {
  if (typeof value !== 'string') return null;
  if (/^[a-f\d]{24}$/i.test(value)) return value.toLowerCase();
  try {
    const url = new URL(value, 'https://www.xiaohongshu.com');
    if (url.protocol !== 'https:' || url.hostname !== 'www.xiaohongshu.com' || url.port || url.username || url.password) return null;
    return /^\/(?:explore|search_result|discovery\/item)\/([a-f\d]{24})\/?$/i.exec(url.pathname)?.[1].toLowerCase() || null;
  } catch { return null; }
}
function cardRecord(card) {
  if (!card || typeof card !== 'object') return null;
  const id = card.id == null || card.id === '' ? noteID(card.url) : noteID(card.id);
  if (!id || (card.id && !/^[a-f\d]{24}$/i.test(card.id))) return null;
  let url;
  if (card.url) {
    let parsed;
    try { parsed = new URL(card.url, 'https://www.xiaohongshu.com'); } catch { return null; }
    if (noteID(parsed.href) !== id) return null;
    parsed.pathname = `/explore/${id}`;
    const access = new URLSearchParams();
    for (const name of ['xsec_token', 'xsec_source']) {
      const value = parsed.searchParams.get(name);
      if (value && value.length <= 2048) access.set(name, value);
    }
    parsed.search = access.toString(); parsed.hash = '';
    url = parsed.href;
  }
  return { id, ...(url ? { url } : {}), title: typeof card.title === 'string' ? card.title.replace(/\u0000/g, '').trim().slice(0, 500) : '' };
}
function hasAccessToken(url) { try { return Boolean(new URL(url).searchParams.get('xsec_token')); } catch { return false; } }
function shouldContinueSearch(stats, { round, maxSearchScrolls, targetUnseen, unchanged = 0, noResults = false }) {
  if (noResults || round + 1 >= maxSearchScrolls || (stats.priorityCandidateCount ?? stats.unseenCandidateCount) >= targetUnseen) return false;
  // A repeatedly shown known card is not evidence that deeper results are empty.
  return stats.skippedKnownNotes > 0 || unchanged < 2;
}
function enrich(existing, card, keyword) {
  existing.keywords.add(keyword);
  if (card.title.length > existing.title.length) existing.title = card.title;
  if (card.url && (!existing.url || hasAccessToken(card.url))) existing.url = card.url;
}

// The first keyword discovering an unseen ID owns its pool. Later keyword
// matches enrich that same candidate, so round-robin visits never repeat it.
function createCandidateSchedule(excludeNoteIds = [], options = {}) {
  const known = new Set(normalizeKnownNoteIds(excludeNoteIds));
  const candidates = new Map(), knownMatches = new Map(), queries = new Map();
  const attempted = new Set();
  let plannedNewDetails = 0;
  function queryFor(keyword) {
    if (typeof keyword !== 'string' || !keyword.trim() || keyword.length > 80) throw new Error('搜索关键词无效。');
    if (!queries.has(keyword)) queries.set(keyword, { seen: new Set(), known: new Set(), unseen: new Set(), pool: [] });
    return queries.get(keyword);
  }
  function stats(keyword) {
    const query = queryFor(keyword);
    return { candidateCount: query.seen.size, skippedKnownNotes: query.known.size, unseenCandidateCount: query.unseen.size,
      ...(options.researchScope === relevance.SCOPE ? { priorityCandidateCount: [...query.unseen].filter(id => relevance.classifyNote(candidates.get(id), { stage: 'card' }).tier === 'focus').length } : {}) };
  }
  function addCards(keyword, cards) {
    const query = queryFor(keyword), before = query.seen.size;
    for (const raw of Array.isArray(cards) ? cards : []) {
      const card = cardRecord(raw); if (!card) continue;
      if (known.has(card.id)) {
        query.seen.add(card.id); query.known.add(card.id);
        const existing = knownMatches.get(card.id);
        if (existing) enrich(existing, card, keyword);
        else knownMatches.set(card.id, { ...card, keywords: new Set([keyword]) });
        continue;
      }
      if (!card.url) continue;
      query.seen.add(card.id); query.unseen.add(card.id);
      const existing = candidates.get(card.id);
      if (existing) enrich(existing, card, keyword);
      else { candidates.set(card.id, { ...card, keywords: new Set([keyword]) }); query.pool.push(card.id); }
    }
    return { ...stats(keyword), newlySeenNotes: query.seen.size - before };
  }
  function plan(maxNotes) {
    if (!Number.isInteger(maxNotes) || maxNotes < 1 || maxNotes > 100) throw new Error('新帖查看上限须为 1–100。');
    if (options.researchScope === relevance.SCOPE) {
      const result = relevance.planCandidates([...candidates.values()].filter(card => !attempted.has(card.id)), maxNotes);
      plannedNewDetails = result.length;
      return result.map(card => ({ ...card, keywords: [...card.keywords] }));
    }
    const pools = [...queries.values()].map(query => [...query.pool]), ordered = [];
    while (pools.some(pool => pool.length) && ordered.length < maxNotes) {
      for (const pool of pools) if (pool.length && ordered.length < maxNotes) ordered.push(pool.shift());
    }
    plannedNewDetails = ordered.length;
    return ordered.map(id => ({ ...candidates.get(id), keywords: [...candidates.get(id).keywords] }));
  }
  function keywordMatches() { return [...knownMatches.values()].map(card => ({ ...card, keywords: [...card.keywords] })); }
  function coverage() { return { knownNoteIds: known.size, skippedKnownNotes: knownMatches.size, unseenCandidateNotes: candidates.size, plannedNewDetails, attemptedNewDetails: attempted.size }; }
  function recordAttempt(id) {
    if (known.has(id) || !candidates.has(id) || attempted.has(id)) throw new Error('不能重复查看已入库、已访问或未发现的帖子。');
    attempted.add(id);
  }
  return { addCards, stats, plan, keywordMatches, coverage, recordAttempt };
}
module.exports = { MAX_KNOWN_IDS, normalizeKnownNoteIds, noteID, shouldContinueSearch, createCandidateSchedule };
