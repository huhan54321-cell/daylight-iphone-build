'use strict';
// Read-only validation against public pages. No authenticated browser or merchant credentials.
const fs = require('node:fs');
const path = require('node:path');
const { SOURCES, normalizeJob } = require('./career-core.cjs');
const { boundedFetch, collectSource } = require('./career-adapters.cjs');
async function main() {
  const request = boundedFetch();
  const checkedAt = new Date().toISOString(), sources = [], jobs = [];
  for (const id of ['unitree', 'zju', 'shixiseng-public']) {
    try {
      const result = await collectSource(id, request, {}, checkedAt);
      const rows = result.jobs.map(raw => normalizeJob(raw, id, checkedAt));
      jobs.push(...rows);
      sources.push({ id, state: result.state, count: rows.length, message: result.message });
    } catch (error) { sources.push({ id, state: error.state || 'error', count: 0, message: error.message }); }
  }
  const report = { checkedAt, sources, jobs, merchantAPI: 'not_account_tested', bossBrowserCollector: 'not_logged_in_tested' };
  if (process.argv.includes('--save')) fs.writeFileSync(path.join(__dirname, 'career-live-check.json'), JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify({ checkedAt, sources, jobTitles: jobs.map(j => ({ sourceID: j.sourceID, title: j.title, status: j.status, city: j.city })) }, null, 2));
}
if (require.main === module) main().catch(() => { console.error('公开源验证未完成'); process.exitCode = 1; });
