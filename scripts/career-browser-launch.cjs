'use strict';

function flagValue(args, flag) {
  const index = args.indexOf(flag);
  if (index < 0) return null;
  const value = args[index + 1];
  if (!value || value.startsWith('--') || !value.trim()) throw new Error(`${flag} 需要提供值。`);
  return value.trim();
}

function browserLaunchOptions(args = [], env = process.env) {
  const cliChannel = flagValue(args, '--browser-channel');
  const cliExecutable = flagValue(args, '--browser-executable');
  const useCli = cliChannel !== null || cliExecutable !== null;
  const channel = useCli ? cliChannel : env.CAREER_BROWSER_CHANNEL?.trim() || null;
  const executablePath = useCli ? cliExecutable : env.CAREER_BROWSER_EXECUTABLE_PATH?.trim() || null;
  if (channel && executablePath) throw new Error('浏览器 channel 与 executablePath 只能选择一个。');
  const options = {
    headless: args.includes('--scheduled'),
    viewport: { width: 1280, height: 900 },
    serviceWorkers: 'block'
  };
  if (channel) options.channel = channel;
  if (executablePath) options.executablePath = executablePath;
  return options;
}

function browserProfileName(options = {}) {
  if (options.channel === 'msedge') return 'browser-boss-edge';
  if (options.channel === 'chrome') return 'browser-boss-chrome';
  return 'browser-boss';
}

module.exports = { browserLaunchOptions, browserProfileName };
