'use strict';
let captured = null, diagnostic = null;
const output = document.getElementById('result'), tokenInput = document.getElementById('token'), importButton = document.getElementById('import');
chrome.storage.local.get('token').then(v => { tokenInput.value = v.token || globalThis.DAYLIGHT_CONNECTION_TOKEN || ''; });
document.getElementById('save').onclick = async () => { await chrome.storage.local.set({ token: tokenInput.value.trim() }); output.textContent = '连接凭据已保存在本机扩展中。'; };
document.getElementById('preview').onclick = async () => {
  captured = null; diagnostic = null; importButton.disabled = true; document.getElementById('diagnostic').hidden = true;
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    const [response] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readCareerPage });
    if (!response?.result) throw new Error('没有读取到页面，请重新打开扩展后重试。');
    if (response.result.error) throw new Error(response.result.error);
    captured = response.result;
    diagnostic = captured.diagnostics || null;
    document.getElementById('diagnostic').hidden = !diagnostic;
    if (!captured.jobs.length) {
      const detail = diagnostic ? `检测到 ${diagnostic.jobLinks} 条可见岗位链接、${diagnostic.cards} 个旧版卡片、${diagnostic.frames} 个内嵌页面。` : '';
      throw new Error('当前页面未取得可读岗位。' + detail + '请确认页面已经显示岗位；仍失败时，点下方“保存页面诊断到电脑”。');
    }
    output.textContent = captured.jobs.map((j, i) => `${i + 1}. ${j.company} · ${j.title}\n${j.location || j.city} · ${j.verification === 'full_jd' ? '已读正文' : '仅列表线索'}`).join('\n\n');
    importButton.disabled = false;
  } catch (e) { output.textContent = e.message; }
};
document.getElementById('diagnostic').onclick = async () => {
  if (!diagnostic) return;
  try {
    const response = await fetch('http://127.0.0.1:4176/v2/career/browser/diagnostics', { method: 'POST', redirect: 'error',
      headers: { Authorization: 'Bearer ' + tokenInput.value.trim(), 'Content-Type': 'application/json' }, body: JSON.stringify(diagnostic), signal: AbortSignal.timeout(10000) });
    const value = await response.json(); if (!response.ok) throw new Error(value.error || '诊断保存失败');
    output.textContent = value.message;
  } catch (error) { output.textContent = error.message; }
};
importButton.onclick = async () => {
  if (!captured) return;
  importButton.disabled = true;
  try {
    const response = await fetch('http://127.0.0.1:4176/v2/career/browser/import', { method: 'POST', redirect: 'error', headers: { 'Authorization': 'Bearer ' + tokenInput.value.trim(), 'Content-Type': 'application/json' }, body: JSON.stringify({ sourceID: captured.sourceID, jobs: captured.jobs }), signal: AbortSignal.timeout(15000) });
    const value = await response.json(); if (!response.ok) throw new Error(value.error || '导入失败');
    output.textContent = `已保存 ${value.imported} 条岗位（按来源链接去重）。手机联网后刷新可见。列表卡片不会覆盖已保存的完整正文。`; captured = null;
  } catch (e) { output.textContent = e.message; importButton.disabled = false; }
};
