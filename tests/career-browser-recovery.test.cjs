'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { isLocalDesktopRequest, loginTarget, openLoginWindow } = require('../scripts/career-browser-recovery.cjs');

test('browser recovery refuses remote, proxied and extension requests even when peer is loopback', () => {
  const base = { socket: { remoteAddress: '127.0.0.1', localPort: 4176 }, headers: { host: '127.0.0.1:4176' } };
  assert.equal(isLocalDesktopRequest(base), true);
  assert.equal(isLocalDesktopRequest({ ...base, headers: { ...base.headers, origin: 'http://127.0.0.1:4176' } }), true);
  for (const headers of [
    { host: 'career.tail.example:443' }, { host: '127.0.0.1:4173' },
    { ...base.headers, 'x-forwarded-for': '100.100.0.1' },
    { ...base.headers, forwarded: 'for=100.100.0.1' },
    { ...base.headers, 'tailscale-user-login': 'private' },
    { ...base.headers, origin: 'chrome-extension://hlmdaklafhleodnklhdbkbjmkbkfmgpc' }
  ]) assert.equal(isLocalDesktopRequest({ ...base, headers }), false);
  assert.equal(isLocalDesktopRequest({ ...base, socket: { ...base.socket, remoteAddress: '100.100.0.1' } }), false);
});

test('recovery uses only fixed official URLs and the collectors own profiles', async () => {
  const input = { dataDir: path.resolve('.test-tmp/career'), xhsDir: path.resolve('.test-tmp/xhs') };
  assert.equal(loginTarget('boss', input.dataDir, input.xhsDir).profile, path.join(input.dataDir, 'browser-boss-edge'));
  assert.equal(loginTarget('xiaohongshu', input.dataDir, input.xhsDir).profile, path.join(input.xhsDir, 'browser-xhs-msedge'));
  assert.throws(() => loginTarget('../evil', input.dataDir, input.xhsDir), /仅支持/);
  let launched;
  const result = await openLoginWindow({ ...input, sourceID: 'boss', url: 'https://evil.test', executable: 'cmd.exe' }, {
    env: { ProgramFiles: 'C:/Program Files' }, exists: () => true,
    spawn(exe, args, options) {
      launched = { exe, args, options };
      const child = new EventEmitter(); child.unref = () => {};
      queueMicrotask(() => child.emit('spawn')); return child;
    }
  });
  assert.match(launched.exe, /msedge\.exe$/);
  assert.equal(launched.args.at(-1), 'https://www.zhipin.com/web/geek/jobs');
  assert.equal(launched.options.shell, false);
  assert.equal(result.state, 'awaiting_user');
  assert.match(result.message, /不代表采集成功/);
});
