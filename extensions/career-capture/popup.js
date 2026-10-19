'use strict';
let captured = null;
const output = document.getElementById('result'), tokenInput = document.getElementById('token'), importButton = document.getElementById('import');
chrome.storage.local.get('token').then(v => { tokenInput.value = v.token || ''; });
document.getElementById('save').onclick = async () => { await chrome.storage.local.set({ token: tokenInput.value.trim() }); output.textContent = '连接凭据已保存在本机扩展中。'; };
function readPage() {
  const clean = (s, n = 4000) => String(s || '').replace(/[\uE000-\uF8FF]/g, '□').trim().slice(0, n);
  const text = (root, selector) => clean(root.querySelector(selector)?.innerText);
  const host = location.hostname;
  const body = document.body.innerText.slice(0, 20000);
  if (/安全验证|滑动.{0,8}验证|访问验证/.test(body)) return { error: '页面要求验证，请本人处理后再读取。' };
  const jobs = [];
  if (host === 'www.zhipin.com' || host === 'zhipin.com') {
    const cards = [...document.querySelectorAll('.job-card-wrapper, .job-card-box')].slice(0, 40);
    for (const card of cards) {
      const url = card.querySelector('a[href*="/job_detail/"]')?.href;
      const title = text(card, '.job-name, .job-title'), company = text(card, '.company-name, .brand-name'), city = text(card, '.job-area, .job-area-wrapper');
      if (url && title && company) jobs.push({ url, title, company, city: city || '城市未注明', jobType: /实习/.test(card.innerText) ? '实习' : '类型未注明', description: '', verification: 'listing_only', requirements: [], sourceNote: '本人浏览器当前搜索页面可见卡片' });
    }
    if (!jobs.length && location.pathname.startsWith('/job_detail/')) {
      const title = text(document, '.job-name h1, .name h1, .job-banner h1'), company = text(document, '.company-info a, .sider-company .company-info a, .company-name');
      const description = text(document, '.job-sec-text, .job-detail-section');
      if (title && company && description) jobs.push({ url: location.href, title, company, city: text(document, '.text-city, .job-area') || '城市未注明', jobType: /实习/.test(title) ? '实习' : '类型未注明', description, verification: 'full_jd', requirements: [], sourceNote: '本人浏览器当前可见岗位正文；具体表单未读取' });
    }
    return { sourceID: 'boss', jobs };
  }
  if (host === 'www.shixiseng.com') {
    for (const card of [...document.querySelectorAll('[data-intern-id]')].slice(0, 40)) {
      const anchor = card.querySelector('a[href*="/intern/inn_"]');
      const company = text(card, '.intern-detail__company a');
      if (anchor && company) jobs.push({ url: anchor.href, title: clean(anchor.innerText), company, city: text(card, '.city') || '城市未注明', jobType: '实习', description: '', verification: 'listing_only', requirements: [] });
    }
    return { sourceID: 'shixiseng-public', jobs };
  }
  return { error: '当前页适配 BOSS 与实习僧。企业官网由电脑服务读取已支持的入口。' };
}
document.getElementById('preview').onclick = async () => {
  captured = null; importButton.disabled = true;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const [response] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readPage });
    if (response.result.error) throw new Error(response.result.error);
    captured = response.result;
    if (!captured.jobs.length) throw new Error('当前页面未取得可读岗位，请打开搜索结果或详情页后重试。');
    output.textContent = captured.jobs.map((j, i) => `${i + 1}. ${j.company} · ${j.title}\n${j.city} · ${j.verification === 'full_jd' ? '已读正文' : '仅列表线索'}`).join('\n\n');
    importButton.disabled = false;
  } catch (e) { output.textContent = e.message; }
};
importButton.onclick = async () => {
  if (!captured) return;
  importButton.disabled = true;
  try {
    const response = await fetch('http://127.0.0.1:4176/v2/career/browser/import', { method: 'POST', redirect: 'error', headers: { 'Authorization': 'Bearer ' + tokenInput.value.trim(), 'Content-Type': 'application/json' }, body: JSON.stringify(captured) });
    const value = await response.json(); if (!response.ok) throw new Error(value.error || '导入失败');
    output.textContent = `已保存 ${value.imported} 条岗位。手机联网后刷新可见。`; captured = null;
  } catch (e) { output.textContent = e.message; importButton.disabled = false; }
};
