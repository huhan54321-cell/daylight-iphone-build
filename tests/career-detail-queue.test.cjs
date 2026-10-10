'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const queue = require('../scripts/career-detail-queue.cjs');
const stamp = '2026-10-06T02:00:00Z';
test('discovery queues only registered actual detail URLs and does not fetch arbitrary URLs', () => {
  const rows = queue.addDiscoveries([], [{ url: 'http://127.0.0.1/secret' }, { url: 'https://www.shixiseng.com/interns?keyword=robot' }, { url: 'https://www.shixiseng.com/intern/inn_example' }], stamp);
  assert.equal(rows.length, 1); assert.equal(rows[0].sourceID, 'shixiseng-public');
  queue.addDiscoveries(rows, [{ url: rows[0].url }], '2026-10-07T00:00:00Z'); assert.equal(rows.length, 1);
});
test('readable search detail becomes factual JD and closed status survives enrichment', async () => {
  const rows = queue.addDiscoveries([], [{ url: 'https://www.shixiseng.com/intern/inn_example' }], stamp);
  const html = '<title>机器人仿真实习生实习招聘-公司A实习生招聘-实习僧</title><div class="job_msg"><span class="job_position">杭州</span></div><div class="resume_apply">当前职位已下线</div><div class="job_detail">负责机器人与MuJoCo仿真开发。</div>';
  const result = await queue.processQueue(rows, async () => html, stamp);
  assert.equal(result.jobs.length, 1); assert.equal(result.jobs[0].verification, 'full_jd'); assert.equal(result.jobs[0].status, 'closed'); assert.equal(rows[0].state, 'done');
});
test('unreadable details stay visible as restrictions and bound retries without inventing requirements', async () => {
  const rows = queue.addDiscoveries([], [{ url: 'https://www.zhipin.com/job_detail/example.html' }], stamp);
  const result = await queue.processQueue(rows, async () => '<html>登录后查看完整正文</html>', stamp);
  assert.equal(result.jobs.length, 0); assert.equal(result.unreadable, 1); assert.equal(rows[0].state, 'unreadable');
  const retry = await queue.processQueue(rows, () => { throw new Error('must not retry immediately'); }, '2026-10-06T03:00:00Z'); assert.equal(retry.attempted.length, 0);
});

test('search discoveries do not fetch details from a source whose automatic collection is disabled', async () => {
  const rows=queue.addDiscoveries([], [{url:'https://www.zhipin.com/job_detail/example.html'}],stamp);
  const result=await queue.processQueue(rows,()=>{throw new Error('disabled source must not be requested');},stamp,2,{disabledSources:['boss']});
  assert.deepEqual(result.attempted,[]);assert.deepEqual(result.jobs,[]);assert.equal(rows[0].attempts,0);
});
