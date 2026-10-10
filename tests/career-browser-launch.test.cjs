'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { browserLaunchOptions, browserProfileName } = require('../scripts/career-browser-launch.cjs');
const { runBrowserCollector } = require('../scripts/career-browser-runner.cjs');

test('BOSS browser launch defaults to packaged Chromium and keeps scheduled mode headless', () => {
  const manual = browserLaunchOptions([], {});
  assert.deepEqual(manual, { headless: false, viewport: { width: 1280, height: 900 }, serviceWorkers: 'block' });
  assert.deepEqual(browserLaunchOptions(['--scheduled'], {}), { ...manual, headless: true });
});

test('explicit Chrome channel or executable path reaches Playwright and CLI overrides environment', () => {
  assert.equal(browserLaunchOptions(['--browser-channel', 'chrome'], {}).channel, 'chrome');
  assert.equal(browserLaunchOptions([], { CAREER_BROWSER_CHANNEL: 'chrome' }).channel, 'chrome');
  const chromePath = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
  assert.equal(browserLaunchOptions([], { CAREER_BROWSER_EXECUTABLE_PATH: chromePath }).executablePath, chromePath);
  assert.equal(browserLaunchOptions(['--browser-executable', chromePath], { CAREER_BROWSER_CHANNEL: 'chrome' }).executablePath, chromePath);
});

test('conflicting or incomplete browser selections fail before launch', () => {
  assert.throws(() => browserLaunchOptions(['--browser-channel', 'chrome', '--browser-executable', 'chrome.exe'], {}), /只能选择一个/);
  assert.throws(() => browserLaunchOptions([], { CAREER_BROWSER_CHANNEL: 'chrome', CAREER_BROWSER_EXECUTABLE_PATH: 'chrome.exe' }), /只能选择一个/);
  assert.throws(() => browserLaunchOptions(['--browser-channel'], {}), /需要提供值/);
});

test('Edge and Chrome authorization profiles stay separate from packaged Chromium', () => {
  assert.equal(browserProfileName(browserLaunchOptions(['--browser-channel', 'msedge'], {})), 'browser-boss-edge');
  assert.equal(browserProfileName(browserLaunchOptions(['--browser-channel', 'chrome'], {})), 'browser-boss-chrome');
  assert.equal(browserProfileName(browserLaunchOptions([], {})), 'browser-boss');
});

test('a default Chromium directory cannot count as an Edge authorization session', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'career-browser-profile-'));
  try {
    fs.mkdirSync(path.join(directory, 'browser-boss'));
    const result = await runBrowserCollector(directory, [], { browserChannel: 'msedge' });
    assert.equal(result.state, 'login_required');
    assert.deepEqual(result.jobs, []);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
