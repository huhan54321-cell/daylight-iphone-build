'use strict';

// These adapters read rendered DOM only. Keep each read* function self-contained:
// Playwright serializes the function before evaluating it in the visible page.
function xhsDocumentIssue(value, body, { allowLogin = false } = {}) {
  let url;
  try { url = new URL(value); } catch {}
  if (!url || url.origin !== 'https://www.xiaohongshu.com' || url.username || url.password) {
    return { state: 'blocked', message: '页面已离开小红书 HTTPS 官网或退回空白页，采集已停止。' };
  }
  const text = String(body || '').trim();
  if (!text) return { state: 'error', message: '小红书页面尚未加载出可见内容，未将空白页作为采集成功。' };
  // Match standalone UI notices, not incidental mentions in post prose.
  const lines = text.split(/[\r\n]+/).map(line => line.trim()).filter(Boolean);
  const challenge = lines.some(line => line.length <= 100 && (
    /^(?:请(?:您)?(?:先)?(?:完成|进行|通过)?|正在进行)?安全验证(?:$|[：:，,。.!！\s]|后|以)/.test(line) ||
    /^(?:请(?:您)?(?:先)?(?:拖动|滑动|移动)?|拖动|滑动|移动)?滑块(?:$|[：:，,。.!！\s]|完成|进行|验证)/.test(line) ||
    /^(?:操作|请求|访问)频繁(?:$|[：:，,。.!！\s]|请|稍后)/.test(line) ||
    /^网络环境异常(?:$|[：:，,。.!！\s]|请)/.test(line)
  ));
  if (/\/(?:captcha|verify|security|challenge)(?:\/|$)/i.test(url.pathname) || challenge) {
    return { state: 'blocked', message: '小红书要求安全验证或限制访问，采集已停止，请在浏览器中自行处理后重试。' };
  }
  const login = lines.some(line => line.length <= 80 && (
    /^(?:请(?:您)?(?:先)?)?登录后(?:查看|搜索)(?:$|[：:，,。.!！\s]|笔记|评论|更多|内容|完整|详情|结果)/.test(line) ||
    /^(?:小红书)?扫码登录(?:$|[：:，,。.!！\s]|后)/.test(line)
  ));
  if (!allowLogin && (/\/(?:login|signin)(?:\/|$)/i.test(url.pathname) || login)) {
    return { state: 'login_required', message: '小红书需要登录或当前会话已过期，请先在浏览器完成登录。' };
  }
  return null;
}

function safeNoteURL(value) {
  let url;
  try { url = new URL(value, 'https://www.xiaohongshu.com'); } catch { return null; }
  if (url.origin !== 'https://www.xiaohongshu.com' || url.username || url.password) return null;
  const match = url.pathname.match(/^\/(?:explore|search_result|discovery\/item)\/([a-f0-9]{24})\/?$/i);
  if (!match) return null;
  url.pathname = `/explore/${match[1].toLowerCase()}`;
  url.hash = '';
  return { id: match[1].toLowerCase(), url: url.href };
}

function readSearchDOM() {
  function visible(element) {
    for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
      if (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true') return false;
      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0') return false;
    }
    return true;
  }
  function content(element) {
    if (!element || !visible(element)) return '';
    function walk(node) {
      if (node.nodeType === 3) return node.nodeValue || '';
      if (node.nodeType !== 1 || !visible(node)) return '';
      if (node.tagName === 'BR') return '\n';
      const value = Array.from(node.childNodes).map(walk).join('');
      return /^(DIV|P|SECTION|ARTICLE|LI|H[1-6])$/.test(node.tagName) ? `\n${value}\n` : value;
    }
    return walk(element).replace(/\u00a0/g, ' ').replace(/[ \t]+/g, ' ').split('\n').map(line => line.trim()).filter(Boolean).join('\n');
  }
  function noteURL(value) {
    let url;
    try { url = new URL(value, 'https://www.xiaohongshu.com'); } catch { return null; }
    if (url.origin !== 'https://www.xiaohongshu.com' || url.username || url.password) return null;
    const match = url.pathname.match(/^\/(?:explore|search_result)\/([a-f0-9]{24})\/?$/i);
    if (!match) return null;
    url.pathname = `/explore/${match[1].toLowerCase()}`;
    url.hash = '';
    return { id: match[1].toLowerCase(), url: url.href };
  }
  const rows = new Map();
  for (const candidate of document.querySelectorAll('section.note-item, .note-item, a[href]')) {
    if (!visible(candidate)) continue;
    const anchors = candidate.tagName === 'A' ? [candidate] : Array.from(candidate.querySelectorAll('a[href]'));
    for (const anchor of anchors) {
      if (!visible(anchor)) continue;
      const note = noteURL(anchor.getAttribute('href'));
      if (!note) continue;
      const card = anchor.closest('.note-item') || candidate;
      let title = '';
      for (const selector of ['.title', '.note-title']) {
        const titleNode = Array.from(card.querySelectorAll(selector)).find(visible);
        if (titleNode) { title = content(titleNode); break; }
      }
      if (!title) title = anchor.getAttribute('title') || content(anchor);
      const previous = rows.get(note.id);
      if (!previous) rows.set(note.id, { ...note, title: title.trim() });
      else {
        if (!previous.title && title) previous.title = title.trim();
        if (!new URL(previous.url).searchParams.has('xsec_token') && new URL(note.url).searchParams.has('xsec_token')) previous.url = note.url;
      }
    }
  }
  return Array.from(rows.values());
}

function readNoteDOM() {
  function visible(element) {
    for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
      if (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true') return false;
      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0') return false;
    }
    return true;
  }
  function content(element) {
    if (!element || !visible(element)) return '';
    function walk(node) {
      if (node.nodeType === 3) return node.nodeValue || '';
      if (node.nodeType !== 1 || !visible(node)) return '';
      if (node.tagName === 'BR') return '\n';
      const value = Array.from(node.childNodes).map(walk).join('');
      return /^(DIV|P|SECTION|ARTICLE|LI|H[1-6])$/.test(node.tagName) ? `\n${value}\n` : value;
    }
    return walk(element).replace(/\u00a0/g, ' ').replace(/[ \t]+/g, ' ').split('\n').map(line => line.trim()).filter(Boolean).join('\n');
  }
  function first(selectors) {
    for (const selector of selectors) {
      const element = Array.from(document.querySelectorAll(selector)).find(element => visible(element) && !element.closest('.comments-container, .comment-container, .comment-item, .reply-container, .reply-item, .comment-item-sub'));
      if (element) return content(element);
    }
    return '';
  }
  return {
    title: first(['#detail-title', '.note-container .title', '.note-detail .title']),
    text: first(['#detail-desc', '.note-container .note-content', '.note-detail .note-content', '.note-content']),
    dateText: first(['.note-container .date', '.note-detail .date']),
    metrics: {
      likes: first(['.note-container .like-wrapper .count', '.note-detail .like-wrapper .count', '.interact-container .like-wrapper .count']),
      collects: first(['.note-container .collect-wrapper .count', '.note-detail .collect-wrapper .count', '.interact-container .collect-wrapper .count']),
      comments: first(['.note-container .chat-wrapper .count', '.note-detail .chat-wrapper .count', '.interact-container .chat-wrapper .count'])
    }
  };
}

function readCommentsDOM() {
  function visible(element) {
    for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
      if (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true') return false;
      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0') return false;
    }
    return true;
  }
  function content(element, omitReplies = false) {
    if (!element || !visible(element)) return '';
    function walk(node) {
      if (node.nodeType === 3) return node.nodeValue || '';
      if (node.nodeType !== 1 || !visible(node)) return '';
      if (node !== element && omitReplies && node.matches('.reply-container, .reply-item, .comment-item-sub, .comment-item, .comment-container')) return '';
      if (node.tagName === 'BR') return '\n';
      const value = Array.from(node.childNodes).map(walk).join('');
      return /^(DIV|P|SECTION|ARTICLE|LI|H[1-6])$/.test(node.tagName) ? `\n${value}\n` : value;
    }
    return walk(element).replace(/\u00a0/g, ' ').replace(/[ \t]+/g, ' ').split('\n').map(line => line.trim()).filter(Boolean).join('\n');
  }
  const boundaries = '.comment-item, .comment-container, .reply-container, .reply-item, .comment-item-sub';
  const replySelector = '.reply-container, .reply-item, .comment-item-sub';
  function owned(root, selector) {
    return Array.from(root.querySelectorAll(selector)).filter(element => {
      if (!visible(element)) return false;
      for (let node = element.parentElement; node && node !== root; node = node.parentElement) {
        if (node.matches(boundaries)) return false;
      }
      return true;
    });
  }
  function first(root, selectors) {
    for (const selector of selectors) {
      const element = owned(root, selector)[0];
      if (element) return content(element, true);
    }
    return '';
  }
  function commentID(root) {
    const explicit = String(root.getAttribute('data-comment-id') || '').trim();
    if (explicit) return explicit;
    const match = String(root.getAttribute('id') || '').match(/^comment[-_:](.+)$/i);
    return match ? match[1] : '';
  }
  function record(root, parentId) {
    // Select the text itself before a potentially broader .content wrapper.
    const text = first(root, ['.note-text', '.content']);
    if (!text) return null;
    const dateText = first(root, ['.date', '.time']);
    let id = commentID(root);
    if (!id) {
      // A clearly local ID preserves reply relationships across repeated DOM
      // snapshots. It is not represented as a Xiaohongshu platform ID.
      let hash = 2166136261;
      // The same short reply can occur in multiple threads. Include its
      // parent, and use an available visible display name only in the hash;
      // no author or account field is returned by this anonymous adapter.
      const author = first(root, ['.author-wrapper .name', '.author .name', '.author-name', '.user-name']);
      const key = `${parentId}\n${text}\n${dateText}\n${author}`;
      for (let index = 0; index < key.length; index++) hash = Math.imul(hash ^ key.charCodeAt(index), 16777619);
      id = `visible-${(hash >>> 0).toString(16).padStart(8, '0')}`;
    }
    return {
      id, parentId, text, dateText,
      likes: first(root, ['.like .count', '.like-container .count', '.like-wrapper .count', '.like-count', '.likes'])
    };
  }
  const containers = Array.from(document.querySelectorAll('.comments-container, .comment-container')).filter(visible);
  const roots = Array.from(document.querySelectorAll('.comments-container .comment-item, .comments-container .comment-container, .comment-container .comment-item, .comment-container'));
  const comments = [];
  const seen = new Set();
  const records = new Map();
  for (const root of roots) {
    if (!visible(root) || root.closest(replySelector)) continue;
    const main = record(root, '');
    if (!main || seen.has(root)) continue;
    seen.add(root);
    records.set(root, main);
    comments.push(main);
    for (const reply of root.querySelectorAll('.reply-container, .reply-item, .comment-item-sub, .reply-container .comment-item, .reply-item .comment-item, .comment-item-sub .comment-item')) {
      if (!visible(reply) || seen.has(reply)) continue;
      let parent = reply.parentElement;
      while (parent && parent !== root && !records.has(parent)) parent = parent.parentElement;
      const row = record(reply, records.get(parent)?.id || main.id);
      if (row) { comments.push(row); seen.add(reply); records.set(reply, row); }
    }
  }
  let displayedTotal = null;
  let visibleEnd = false;
  for (const container of containers) {
    for (const element of container.querySelectorAll('.total, .comments-title, .title')) {
      if (!visible(element) || element.closest('.comment-item, .reply-item, .comment-item-sub, .content, .note-text')) continue;
      const match = content(element).match(/(?:共\s*)?([\d,]+(?:\.\d+)?\s*(?:万|千|w|k)?)\s*条评论|评论\s*[（(]\s*([\d,]+)\s*[）)]/i);
      if (!match) continue;
      const number = (match[1] || match[2]).replace(/[,\s]/g, '');
      const suffix = number.match(/[万千wk]$/i)?.[0];
      const factor = /[万w]/i.test(suffix || '') ? 10000 : /[千k]/i.test(suffix || '') ? 1000 : 1;
      displayedTotal = Math.round(Number.parseFloat(number) * factor);
      if (!Number.isFinite(displayedTotal)) displayedTotal = null;
      if (displayedTotal !== null) break;
    }
    for (const element of container.querySelectorAll('*')) {
      if (!visible(element) || element.children.length || element.closest('.comment-item, .reply-item, .comment-item-sub, .content, .note-text')) continue;
      // An exact notice inside the comments area counts; a phrase quoted by a
      // user, or a search-result footer outside this container, does not.
      if (/^(?:没有更多评论(?:了)?|已显示全部评论|全部评论已显示|没有更多了|暂无评论|还没有评论)[。.!！]?$/.test(content(element))) visibleEnd = true;
    }
  }
  return { comments, displayedTotal, visibleEnd };
}

module.exports = { xhsDocumentIssue, safeNoteURL, readSearchDOM, readNoteDOM, readCommentsDOM };
