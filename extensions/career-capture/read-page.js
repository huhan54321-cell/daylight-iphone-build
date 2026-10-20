'use strict';
// Serialized into the active tab by Chrome/Edge; keep all helpers local.
function readCareerPage() {
  const clean = (s, n = 4000) => String(s || '').replace(/[\uE000-\uF8FF]/g, '□').trim().slice(0, n);
  const visible = element => {
    if (!element || !element.getClientRects().length) return false;
    for (let node = element; node?.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node.hidden || node.getAttribute('aria-hidden') === 'true' || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
    }
    return true;
  };
  const text = (root, selectors) => {
    for (const selector of selectors.split(',')) {
      const value = clean([...root.querySelectorAll(selector.trim())].find(visible)?.innerText);
      if (value) return value;
    }
    return '';
  };
  const host = location.hostname;
  if (!['www.zhipin.com', 'zhipin.com', 'www.shixiseng.com'].includes(host) || location.protocol !== 'https:') return { error: '请打开 BOSS 或实习僧 HTTPS 官网的搜索结果或岗位详情。' };
  const body = document.body.innerText.slice(0, 30000);
  if (/\/(?:verify|captcha|security)(?:[/.]|$)/i.test(location.pathname) ||
      body.split(/\n/).some(line => /^(?:请先|请|完成)?(?:安全验证|访问验证|滑动.{0,8}验证)(?:$|[，。：:！]|后)/.test(line.trim()))) {
    return { error: '页面要求验证，请本人完成后再读取；没有保存任何岗位。' };
  }
  const jobs = [], seen = new Set();
  const append = job => { if (!seen.has(job.url)) { seen.add(job.url); jobs.push(job); } };
  if (host === 'www.zhipin.com' || host === 'zhipin.com') {
    const jobURL = value => {
      try {
        const u = new URL(value, location.href);
        if (u.protocol !== 'https:' || !['www.zhipin.com', 'zhipin.com'].includes(u.hostname) || u.username || u.password || !/^\/job_detail\/[A-Za-z0-9_-]+\.html$/.test(u.pathname)) return null;
        return u.origin + u.pathname;
      } catch { return null; }
    };
    const links = [...document.querySelectorAll('a[href]')].filter(a => visible(a) && jobURL(a.href));
    const titleSelectors = '.job-name, .job-title, [class*="job-name"], [class*="job-title"]';
    // The user's saved diagnostic and visual confirmation identify this compact
    // footer as a company label. A general .boss-name may instead be a recruiter.
    const compactCompanySelector = 'li.job-card-box > .job-card-footer:has(> .company-location) > a.boss-info:has(.boss-logo img) .boss-name';
    const companySelectors = '.company-name, .brand-name, .company-title, [class*="company-name"], [class*="brand-name"], ' + compactCompanySelector;
    const companyText = root => text(root, companySelectors) || clean([...root.querySelectorAll('a[href]')].find(a => {
      if (!visible(a)) return false;
      try {
        const u = new URL(a.href);
        return u.protocol === 'https:' && ['www.zhipin.com', 'zhipin.com'].includes(u.hostname) && /^\/gongsi\/[A-Za-z0-9_-]+\.html$/.test(u.pathname);
      } catch { return false; }
    })?.innerText);
    const structure = node => ({ tag: node.tagName.toLowerCase(), classes: [...node.classList].filter(c => /^[a-z][a-z0-9_-]{0,79}$/i.test(c)).slice(0, 8), textLength: clean(node.innerText).length });
    const diagnostics = {
      version: 1, sourceID: 'boss', pageKind: location.pathname.startsWith('/job_detail/') ? 'detail' : /\/web\/geek\/jobs/.test(location.pathname) ? 'search' : 'other',
      readyState: document.readyState, jobLinks: links.length, frames: document.querySelectorAll('iframe').length,
      cards: document.querySelectorAll('.job-card-wrapper, .job-card-box').length,
      titleFields: document.querySelectorAll(titleSelectors).length, companyFields: document.querySelectorAll(companySelectors).length,
      // No URLs, cookies, raw HTML, account names, job text, or browser storage.
      samples: links.slice(0, 2).map(a => {
        const parents = []; let node = a;
        for (let depth = 0; node && node !== document.body && depth < 5; depth++, node = node.parentElement) parents.push(structure(node));
        const root = a.closest('li, .job-card-wrapper, .job-card-box, [class*="job-card"]') || a.parentElement;
        return { parents, children: [...(root?.querySelectorAll('*') || [])].filter(visible).slice(0, 35).map(structure) };
      })
    };
    // On a detail page prefer its prose over any related-job cards.
    const detail = [...document.querySelectorAll('.job-sec-text, .job-detail-section .text')].find(visible);
    const title = text(document, '.job-name h1, .name h1, .job-banner h1');
    const company = text(document, '.sider-company .company-info a, .company-info .name, .company-info a, .job-banner .company-name');
    if (location.pathname.startsWith('/job_detail/') && title && company && detail) {
      const description = clean(detail.innerText);
      append({ url: location.href, title, company, city: text(document, '.text-city, .job-area').split(/[·•\s]/)[0] || '城市未注明',
        salary: text(document, '.salary'), jobType: /实习/.test(title + ' ' + text(document, '.job-primary, .job-banner')) ? '实习' : '类型未注明',
        description, verification: description.length >= 80 ? 'full_jd' : 'listing_only', requirements: [], sourceNote: '本人浏览器当前可见岗位正文；未读取投递表单' });
    }
    if (!jobs.length) for (const anchor of links) {
      if (jobs.length >= 40) break;
      const url = jobURL(anchor.href);
      if (seen.has(url)) continue;
      let card = anchor;
      // Stop before a container that mixes distinct postings. Company and title
      // must belong to the same visible job, even when CSS class names change.
      for (let node = anchor.parentElement, depth = 0; node && node !== document.body && depth < 6; node = node.parentElement, depth++) {
        const urls = new Set([...node.querySelectorAll('a[href]')].filter(visible).map(a => jobURL(a.href)).filter(Boolean));
        if (urls.size > 1) break;
        card = node;
        if (companyText(card) && text(card, titleSelectors)) break;
      }
      const title = text(card, titleSelectors) || clean(anchor.innerText).split('\n').map(v => v.trim()).find(Boolean);
      const company = companyText(card);
      // Keep the complete visible district/business area; city remains separate
      // for filtering. Never substitute a company's registered/head-office address.
      const locationText = text(card, '.company-location, .job-area-wrapper, .job-area, .job-location, [class*="job-area"]');
      if (title) append({ url, title, company: company || '公司待核查（未读取）', city: locationText.split(/[·•\s]/)[0] || '城市未注明',
        location: locationText, salary: text(card, '.salary, .job-salary'), jobType: /实习/.test(card.innerText) ? '实习' : '类型未注明',
        description: '', verification: 'listing_only', requirements: [],
        sourceNote: '本人浏览器当前页面可见岗位链接；正文尚未读取' + (company ? '' : '；公司字段未能读取，需在原帖核查') });
    }
    return { sourceID: 'boss', jobs, diagnostics };
  }
  for (const card of [...document.querySelectorAll('[data-intern-id]')].filter(visible).slice(0, 40)) {
    const anchor = [...card.querySelectorAll('a[href*="/intern/inn_"]')].find(visible);
    const company = text(card, '.intern-detail__company a');
    if (anchor && company) append({ url: anchor.href, title: clean(anchor.innerText), company, city: text(card, '.city') || '城市未注明', jobType: '实习', description: '', verification: 'listing_only', requirements: [] });
  }
  return { sourceID: 'shixiseng-public', jobs };
}
if (typeof module !== 'undefined') module.exports = { readCareerPage };
