'use strict';
// Desktop-only launcher. Diagnostics contain no credentials, request bodies, or job content.
const fs = require('node:fs');
const path = require('node:path');
const net = require('node:net');
const { createCareerService } = require('./career-server.cjs');

function connectionEvent(req, status, now = new Date().toISOString()) {
  let route = 'other';
  try {
    const name = new URL(req.url, 'http://localhost').pathname;
    if (['/health', '/v1/career/feed', '/v2/career/snapshot'].includes(name)) route = name;
    else if (name.startsWith('/v2/career/')) route = '/v2/career/*';
  } catch {}
  const userAgent = String(req.headers['user-agent'] || '');
  const forwarded = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return { at: now, method: ['GET', 'POST', 'OPTIONS'].includes(req.method) ? req.method : 'OTHER', route, status,
    client: /CFNetwork|Darwin/.test(userAgent) ? 'apple-app' : /iPhone|iPad/.test(userAgent) ? 'apple-browser' : 'other',
    peer: net.isIP(forwarded) ? forwarded : req.socket.remoteAddress || null };
}

function run() {
  const dataDir = path.resolve(__dirname, '../data/career-private');
  const service = createCareerService({ dataDir, seedFile: path.resolve(__dirname, '../ios/Daylight/CareerSeed.json') });
  const log = path.join(dataDir, 'connections.jsonl');
  service.server.prependListener('request', (req, res) => {
    res.once('finish', () => {
      try {
        if (fs.existsSync(log) && fs.statSync(log).size > 1024 * 1024) fs.renameSync(log, log + '.previous');
        fs.appendFileSync(log, JSON.stringify(connectionEvent(req, res.statusCode)) + '\n', { mode: 0o600 });
      } catch { /* Diagnostics must never interrupt the service. */ }
    });
  });
  service.server.listen(4176, '127.0.0.1', () => {
    fs.writeFileSync(path.join(dataDir, 'service.pid'), String(process.pid));
    console.log(`${new Date().toISOString()} Career service ready at 127.0.0.1:4176`);
    service.assistant.startScheduler();
    console.log('Daily discovery enabled: 09:00 Asia/Shanghai, with one catch-up per day.');
  });
  service.server.on('error', error => { console.error(`Career service failed: ${error.code || 'unknown'}`); process.exitCode = 1; });
  let stopping = false;
  async function stop() {
    if (stopping) return;
    stopping = true;
    service.server.close();
    await service.assistant.close();
  }
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  return service;
}
if (require.main === module) run();
module.exports = { connectionEvent, run };
