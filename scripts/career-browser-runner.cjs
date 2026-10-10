'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const { browserLaunchOptions, browserProfileName } = require('./career-browser-launch.cjs');
function runBrowserCollector(dataDir, queries, config) {
  return new Promise(resolve => {
    const startedAt = Date.now();
    const args = [path.join(__dirname, 'career-browser-collector.mjs'), '--source', 'boss', '--collect', '--scheduled', '--output-only', '--data-dir', dataDir];
    if (config.browserChannel && config.browserChannel !== 'chromium') args.push('--browser-channel', config.browserChannel);
    const profile = browserProfileName(browserLaunchOptions(args));
    if (!fs.existsSync(path.join(dataDir, profile))) return resolve({ state: 'login_required', jobs: [], message: '定期 BOSS 采集尚无所选浏览器的本机授权会话；先自行运行 --login。' });
    // Only this repository's fixed collector is launched, never a config-supplied command.
    const child = spawn(process.execPath, args, {
      cwd: path.resolve(__dirname, '..'), windowsHide: true, stdio: 'ignore', env: { ...process.env, CAREER_COLLECT_QUERIES: JSON.stringify(queries), CAREER_PAGES_PER_QUERY: String(config.pagesPerQuery), CAREER_MAX_DETAILS: String(config.maxDetailsPerSource), CAREER_MAX_PAGE_ACTIONS: String(Math.min(config.maxRequestsPerRefresh, queries.length * config.pagesPerQuery + config.maxDetailsPerSource)) }
    });
    let finished = false;
    const timer = setTimeout(() => { child.kill(); finish({ state: 'error', jobs: [], message: '本机浏览器采集超时；已有缓存保留，稍后重试。' }); }, 120000);
    function finish(result) { if (finished) return; finished = true; clearTimeout(timer); resolve(result); }
    child.on('error', () => finish({ state: 'error', jobs: [], message: '本机浏览器采集器启动失败，请检查可选 Playwright 环境。' }));
    child.on('exit', () => {
      try {
        const stateFile = path.join(dataDir, 'boss-last-state.json'), report = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
        if (Date.parse(report.finishedAt) < startedAt - 1000) throw new Error('stale report');
        let jobs = [];
        const file = path.join(dataDir, 'boss-last-import.json');
        if (report.partialSaved && fs.existsSync(file) && fs.statSync(file).mtimeMs >= startedAt - 1000) jobs = JSON.parse(fs.readFileSync(file, 'utf8')).jobs;
        finish({ state: report.state, jobs, coverage: report.coverage, message: report.message });
      } catch { finish({ state: 'error', jobs: [], message: '本机采集器未产生有效新记录；旧记录保留。' }); }
    });
  });
}
module.exports = { runBrowserCollector };
