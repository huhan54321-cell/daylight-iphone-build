'use strict';

// Application login flow. It reveals the site's own login UI and never fills
// account identifiers, passwords, verification codes, or security challenges.
async function ensureLoginDialog(page) {
  const modal = page.locator('.login-container, .login-modal, .reds-login-container').filter({ visible: true });
  if (await modal.count() > 0) return 'visible';
  const buttons = [
    page.locator('.side-bar .login-btn, .sidebar .login-btn, .login-btn').filter({ visible: true, hasText: /^\s*登录\s*$/ }),
    page.getByRole('button', { name: '登录', exact: true }).filter({ visible: true }),
    page.getByText('登录', { exact: true }).filter({ visible: true })
  ];
  for (const candidate of buttons) {
    // An ambiguous target cannot count as the account-login control.
    if (await candidate.count() !== 1) continue;
    await candidate.click({ timeout: 3000 });
    await modal.first().waitFor({ state: 'visible', timeout: 6000 }).catch(() => {});
    return await modal.count() > 0 ? 'visible' : 'requested';
  }
  return 'unavailable';
}

async function saveLoginPreview(page, file) {
  const qr = await page.evaluate(() => {
    const visible = element => {
      const box = element.getBoundingClientRect(), style = getComputedStyle(element);
      return box.width > 0 && box.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
    };
    const heading = [...document.querySelectorAll('h1,h2,h3,div,p,span')].find(element => visible(element) && element.textContent.trim() === '手机号登录');
    let modal = heading;
    while (modal && modal !== document.body) {
      const box = modal.getBoundingClientRect();
      if (box.width >= 500 && box.width <= 1100 && box.height >= 300 && box.height <= 850 && modal.textContent.includes('扫码')) break;
      modal = modal.parentElement;
    }
    if (!modal || modal === document.body) return null;
    const candidates = [...modal.querySelectorAll('img,canvas,svg')].filter(element => {
      if (!visible(element)) return false;
      const box = element.getBoundingClientRect();
      if (box.width < 110 || box.width > 350 || Math.abs(box.width - box.height) > 15) return false;
      const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
      return element === hit || element.contains(hit);
    });
    if (candidates.length !== 1) return null;
    const box = candidates[0].getBoundingClientRect(), margin = 24;
    const x = Math.max(0, Math.floor(box.x - margin)), y = Math.max(0, Math.floor(box.y - margin));
    return { x, y, width: Math.min(innerWidth - x, Math.ceil(box.width + margin * 2)), height: Math.min(innerHeight - y, Math.ceil(box.height + margin * 2)) };
  });
  if (qr) { await page.screenshot({ path: file, clip: qr, animations: 'disabled', timeout: 5000 }); return; }
  const modal = page.locator('.login-container, .login-modal, .reds-login-container').filter({ visible: true }).first();
  if (await modal.isVisible().catch(() => false)) await modal.screenshot({ path: file, animations: 'disabled', timeout: 5000 });
  else await page.screenshot({ path: file, fullPage: false, animations: 'disabled', timeout: 5000 });
}
module.exports = { ensureLoginDialog, saveLoginPreview };
