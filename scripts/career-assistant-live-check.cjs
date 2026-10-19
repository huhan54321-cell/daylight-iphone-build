'use strict';
// Explicit read-only platform acceptance probe; never sends a message or application.
const fs = require('node:fs');
const path = require('node:path');
const { runXHSCollector } = require('./xhs-browser-runner.cjs');
const { runBrowserCollector } = require('./career-browser-runner.cjs');
const { collectShixiSearch } = require('./career-public-discovery.cjs');
const { boundedFetch } = require('./career-adapters.cjs');
const { profile, xhsConfig } = require('./career-assistant-domain.cjs');
async function main() {
  const now = new Date().toISOString(), selected = process.argv[2];
  let result;
  if (selected === 'xiaohongshu') {
    const config = { ...xhsConfig([profile({})], now), keywords: ['具身智能 实习招聘'], maxNotes: 3, maxSearchScrolls: 1 };
    result = await runXHSCollector({ dataDir: path.resolve(__dirname, '../data/xhs-private'), config, mode: 'collect', onProgress: p => console.log(JSON.stringify({ phase: p.phase, notesCount: p.notesCount })) }, { timeoutMs: 150000 }).promise;
  } else if (selected === 'boss') result = await runBrowserCollector(path.resolve(__dirname, '../data/career-private'), [{ keyword: '具身智能', city: '杭州' }], { browserChannel: 'msedge', pagesPerQuery: 1, maxDetailsPerSource: 1, maxRequestsPerRefresh: 3 });
  else if (selected === 'shixiseng') result = await collectShixiSearch(boundedFetch(), { CAREER_QUERIES: [{ keyword: '具身智能', city: '杭州' }], CAREER_MAX_DETAILS: 2 }, now);
  else throw new Error('指定 xiaohongshu、boss 或 shixiseng');
  const summary = { checkedAt: now, source: selected, state: result.state, message: result.message, notes: result.notes?.length || 0, jobs: result.jobs?.length || 0, coverage: result.coverage };
  fs.mkdirSync(path.resolve(__dirname, '../verification'), { recursive: true });
  fs.writeFileSync(path.resolve(__dirname, `../verification/assistant-live-${selected}.json`), JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary));
}
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
