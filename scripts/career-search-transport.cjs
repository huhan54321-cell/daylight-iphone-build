'use strict';
const { spawn } = require('node:child_process');
const path = require('node:path');

function createSearchFetch(baseFetch = global.fetch, env = process.env, options = {}) {
  const spawnProcess = options.spawn || spawn;
  return async function searchFetch(url, settings = {}) {
    const target = new URL(url);
    if ((options.platform || process.platform) !== 'win32' || env.CAREER_TAVILY_TRANSPORT !== 'windows' || target.origin !== 'https://api.tavily.com' || target.pathname !== '/search') return baseFetch(url, settings);
    if (settings.signal?.aborted) throw Object.assign(new Error('Search request cancelled'), { name: 'AbortError' });
    const payload = JSON.stringify({ body: settings.body, authorization: settings.headers?.Authorization, proxy: env.HTTPS_PROXY || env.HTTP_PROXY || '' });
    return new Promise((resolve, reject) => {
      // Credentials travel through stdin only; never shell text, process arguments or logs.
      const child = spawnProcess(env.CAREER_POWERSHELL || 'powershell.exe', ['-NoProfile', '-NonInteractive', '-File', path.join(__dirname, 'career-search-request.ps1')], { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'], shell: false });
      let chunks = [], size = 0, finished = false;
      const finish = (error, response) => {
        if (finished) return;
        finished = true;
        settings.signal?.removeEventListener('abort', abort);
        error ? reject(error) : resolve(response);
      };
      const abort = () => { child.kill(); finish(Object.assign(new Error('Search request cancelled'), { name: 'AbortError' })); };
      settings.signal?.addEventListener('abort', abort, { once: true });
      child.on('error', () => finish(new Error('Windows search transport unavailable')));
      child.stdin.on('error', () => finish(new Error('Windows search transport unavailable')));
      child.stdout.on('data', chunk => {
        size += chunk.length;
        if (size > 4 * 1024 * 1024) { child.kill(); finish(new Error('Search response too large')); }
        else chunks.push(chunk);
      });
      child.on('close', code => {
        if (finished) return;
        try {
          if (code !== 0) throw new Error();
          const value = JSON.parse(Buffer.concat(chunks).toString('utf8').replace(/^\uFEFF/, ''));
          if (!Number.isInteger(value.status) || value.status < 200 || value.status > 599 || typeof value.body !== 'string') throw new Error();
          finish(null, new Response(value.body, { status: value.status, headers: { 'Content-Type': 'application/json' } }));
        } catch { finish(new Error('Windows search transport returned invalid data')); }
      });
      child.stdin.end(payload);
    });
  };
}
module.exports = { createSearchFetch };
