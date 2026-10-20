'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

// Browser management is available only to the workbench on this computer.
// Tailscale Serve also connects from loopback, so the peer address alone is
// insufficient: reject its forwarded headers and non-loopback Host as well.
function isLocalDesktopRequest(req) {
  if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress)) return false;
  if (Object.keys(req.headers).some(h => /^(forwarded|x-forwarded-|tailscale-)/i.test(h))) return false;
  const hosts = ['127.0.0.1', 'localhost', '[::1]'].map(h => `${h}:${req.socket.localPort}`);
  if (!hosts.includes(req.headers.host)) return false;
  return !req.headers.origin || req.headers.origin === `http://${req.headers.host}`;
}

function loginTarget(sourceID, dataDir, xhsDir) {
  if (sourceID === 'boss') return { profile: path.resolve(dataDir, 'browser-boss-edge'), url: 'https://www.zhipin.com/web/geek/jobs' };
  if (sourceID === 'xiaohongshu') return { profile: path.resolve(xhsDir, 'browser-xhs-msedge'), url: 'https://www.xiaohongshu.com/explore' };
  throw Object.assign(new Error('仅支持 BOSS 和小红书的专用登录窗口'), { status: 400 });
}

async function openLoginWindow({ sourceID, dataDir, xhsDir }, dependencies = {}) {
  const target = loginTarget(sourceID, dataDir, xhsDir);
  const env = dependencies.env || process.env;
  const exists = dependencies.exists || fs.existsSync;
  const exe = [env['ProgramFiles(x86)'], env.ProgramFiles].filter(Boolean)
    .map(root => path.join(root, 'Microsoft/Edge/Application/msedge.exe')).find(exists);
  if (!exe) throw Object.assign(new Error('没有找到 Microsoft Edge，请先在电脑安装浏览器。'), { status: 409 });
  const launch = dependencies.spawn || spawn;
  await new Promise((resolve, reject) => {
    const child = launch(exe, [`--user-data-dir=${target.profile}`, '--no-first-run', '--new-window', target.url],
      { shell: false, detached: true, stdio: 'ignore', windowsHide: false });
    child.once('error', () => reject(Object.assign(new Error('专用登录窗口未能打开，请检查 Edge。'), { status: 409 })));
    child.once('spawn', () => { child.unref(); resolve(); });
  });
  return { state: 'awaiting_user', message: '已打开专用浏览器。请本人完成登录或验证，确认能搜索，再关闭该窗口后恢复检查；打开窗口不代表采集成功。' };
}
module.exports = { isLocalDesktopRequest, loginTarget, openLoginWindow };
