'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

function runXHSCollector({ dataDir, config = {}, mode, onProgress = () => {} }, options = {}) {
  if (!['login', 'collect', 'enrich-images', 'recheck'].includes(mode)) throw new Error('不支持的采集动作');
  const root = path.resolve(dataDir);
  const runID = crypto.randomUUID();
  const runDir = path.join(root, 'runs', runID);
  fs.mkdirSync(runDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(root, '.gitignore'), '*\n', { mode: 0o600 });
  const configFile = path.join(runDir, 'config.json');
  fs.writeFileSync(configFile, JSON.stringify(config), { mode: 0o600 });
  const launch = options.spawn || spawn;
  const child = launch(process.execPath, [path.join(__dirname, 'xhs-browser-collector.mjs'), '--mode', mode, '--data-dir', root, '--run-dir', runDir, '--config', configFile], {
    cwd: path.resolve(__dirname, '..'), windowsHide: true, stdio: ['pipe', 'pipe', 'pipe']
  });
  child.stdin?.on('error', () => {});
  function requestCancel() {
    if (!child.stdin || child.stdin.destroyed || child.stdin.writableEnded) return;
    try { child.stdin.write('cancel\n'); } catch { /* An already-exited child must not crash the server. */ }
  }
  let cancelled = false, timedOut = false, settled = false, buffered = '', timer, killTimer, finishRun;
  const promise = new Promise(resolve => {
    const finish = (fallbackState, fallbackMessage) => {
      if (settled) return;
      settled = true; clearTimeout(timer); clearTimeout(killTimer);
      let result;
      try {
        const file = path.join(runDir, 'result.json');
        if (fs.statSync(file).size > 20 * 1024 * 1024) throw new Error('size');
        result = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (!Array.isArray(result.notes) || typeof result.coverage !== 'object') throw new Error('invalid');
      } catch { result = { notes: [], keywordMatches: [], coverage: { partial: true } }; }
      if (!Array.isArray(result.keywordMatches)) result.keywordMatches = [];
      if (!Array.isArray(result.imageUpdates)) result.imageUpdates = [];
      if (cancelled) { result.state = 'cancelled'; result.message = '已停止；已取得的部分数据保留。'; }
      else if (timedOut) { result.state = 'error'; result.message = '本次任务超时；已取得的部分数据保留。'; }
      else if (fallbackState) { result.state = fallbackState; result.message = fallbackMessage; }
      else if (!result.state) { result.state = 'error'; result.message = '采集器没有产生有效结果；已有报告保留。'; }
      resolve(result);
    };
    finishRun = finish;
    child.stdout?.on('data', bytes => {
      buffered += bytes.toString('utf8');
      if (buffered.length > 65536) buffered = buffered.slice(-65536);
      const lines = buffered.split('\n'); buffered = lines.pop();
      for (const line of lines) {
        try {
          const item = JSON.parse(line);
          if (item.type === 'progress') onProgress({ phase: String(item.phase || '').slice(0, 80), message: String(item.message || '').slice(0, 1000), notesCount: Number(item.notesCount) || 0, commentsCount: Number(item.commentsCount) || 0, ...(item.imagesCount !== undefined ? { imagesCount: Math.max(0, Math.min(18000, Number(item.imagesCount) || 0)) } : {}) });
        } catch { /* Never forward arbitrary child logs or credentials. */ }
      }
    });
    child.stderr?.on('data', () => {});
    child.on('error', () => finish('error', '浏览器采集器启动失败，请检查 Node 与 Playwright 安装。'));
    child.on('close', () => finish());
    timer = setTimeout(() => {
      timedOut = true; requestCancel();
      killTimer = setTimeout(() => { child.kill(); finish(); }, 6000);
    }, options.timeoutMs || (mode === 'login' ? 10 * 60 * 1000 : 12 * 60 * 1000));
  });
  function cancel() {
    if (settled || cancelled) return;
    cancelled = true; requestCancel();
    killTimer = setTimeout(() => { child.kill(); finishRun(); }, 6000);
  }
  return { promise, cancel, previewFile: mode === 'login' ? path.join(runDir, 'login-preview.png') : null };
}
module.exports = { runXHSCollector };
