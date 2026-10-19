'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const MAX_PNG_BYTES = 8 * 1024 * 1024;

// Serialized into Playwright's page. This reads rendered gallery elements only;
// it does not inspect framework state or request an image URL from a CDN.
function readVisibleGalleryDOM() {
  const excluded = '.comments-container, .comment-container, .comment-item, .reply-container, .author-container, .author-wrapper, .user-profile, .note-item, .recommend-container, .recommend-list, .recommend-panel, .recommendations';
  function visible(element) {
    for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
      if (node.hasAttribute('hidden') || node.getAttribute('aria-hidden') === 'true') return false;
      const style = window.getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0') return false;
    }
    const box = element.getBoundingClientRect();
    return box.width > 0 && box.height > 0 && box.right > 0 && box.bottom > 0 && box.left < window.innerWidth && box.top < window.innerHeight;
  }
  function intersection(box, rootBox) {
    const left = Math.max(0, box.left, rootBox.left), top = Math.max(0, box.top, rootBox.top);
    const right = Math.min(window.innerWidth, box.right, rootBox.right), bottom = Math.min(window.innerHeight, box.bottom, rootBox.bottom);
    return { left, top, right, bottom, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
  }
  function pictures(root) {
    const rootBox = root.getBoundingClientRect();
    return [...root.querySelectorAll('img, .note-image, .image-container, [role="img"]')].flatMap(element => {
      if (!visible(element) || element.closest(excluded)) return [];
      const box = element.getBoundingClientRect(), shown = intersection(box, rootBox);
      if (shown.width < 120 || shown.height < 120) return [];
      let source = '';
      if (element.tagName === 'IMG') {
        if (!element.complete || element.naturalWidth < 2) return [];
        source = element.currentSrc || element.getAttribute('src') || '';
      } else {
        const background = window.getComputedStyle(element).backgroundImage || '';
        if (!/^url\(/i.test(background)) return [];
        source = background;
      }
      if (!source || /^(?:data:image\/svg|about:blank)/i.test(source)) return [];
      const hit = document.elementFromPoint(shown.left + shown.width / 2, shown.top + shown.height / 2);
      if (!hit || !(element === hit || element.contains(hit) || hit.contains(element))) return [];
      return [{ element, source, box, shown, area: shown.width * shown.height, active: !!element.closest('.swiper-slide-active') }];
    });
  }
  const selectors = [
    '.note-container .media-container', '.note-detail .media-container',
    '.note-container .note-slider', '.note-detail .note-slider',
    '.note-container .swiper', '.note-detail .swiper',
    '.note-container .slider-container', '.note-detail .slider-container'
  ];
  let root, picture;
  for (const selector of selectors) {
    const candidates = [...document.querySelectorAll(selector)].filter(element => visible(element) && !element.closest(excluded));
    const galleries = candidates.flatMap(element => {
      if ([...element.querySelectorAll('video')].some(visible)) return [];
      const choices = pictures(element).sort((a, b) => Number(b.active) - Number(a.active) || b.area - a.area);
      return choices.length ? [{ root: element, picture: choices[0] }] : [];
    });
    if (galleries.length > 1) return { available: false, reason: '页面同时出现多个可见图片区域，无法确认唯一的帖子图片。' };
    if (galleries.length === 1) { ({ root, picture } = galleries[0]); break; }
  }
  if (!root) return { available: false, reason: '没有识别到已加载的可见帖子图片；视频、加载失败或页面结构变化均不会用整页截图替代。' };
  const rootBox = root.getBoundingClientRect();
  let page = null, total = null;
  const indicators = [...root.querySelectorAll('.pagination, .swiper-pagination, .number, .page-number, .image-count, .slider-indicator, .slider-indicator-text')].filter(visible);
  for (const indicator of indicators) {
    const match = String(indicator.textContent || '').trim().match(/^(\d{1,3})\s*\/\s*(\d{1,3})$/);
    if (match && Number(match[1]) >= 1 && Number(match[1]) <= Number(match[2])) { page = Number(match[1]); total = Number(match[2]); break; }
  }
  const activeSlide = picture.element.closest('.swiper-slide-active');
  if (page === null && activeSlide && /^\d{1,3}$/.test(activeSlide.getAttribute('data-swiper-slide-index') || '')) page = Number(activeSlide.getAttribute('data-swiper-slide-index')) + 1;
  const dotLists = [...root.querySelectorAll('.pagination-list')].filter(visible);
  if (dotLists.length === 1 && total === null) {
    const dots = [...dotLists[0].querySelectorAll('.pagination-item')].filter(visible);
    const activeDots = dots.map((dot, index) => [...dot.querySelectorAll('.dot.active')].some(visible) ? index : -1).filter(index => index >= 0);
    if (dots.length && activeDots.length === 1) {
      const displayedPage = activeDots[0] + 1;
      if (page !== null && page !== displayedPage) return { available: false, reason: '图片页码与可见轮播指示点尚未一致，等待页面稳定。' };
      page = displayedPage; total = dots.length;
    }
  }
  const nextSelector = '.swiper-button-next, .arrow-controller.right, .arrow-right, .next-arrow, .next-btn, .next-button, [aria-label="下一张"], [aria-label="下一页"], [title="下一张"], [title="下一页"]';
  const controls = [...root.querySelectorAll(nextSelector)].filter(element => visible(element) && !element.closest(excluded));
  let next = null, nextDisabled = false;
  if (controls.length === 1) {
    const control = controls[0], classes = String(control.getAttribute('class') || '');
    nextDisabled = control.hasAttribute('disabled') || control.getAttribute('aria-disabled') === 'true' || /(?:^|\s)(?:swiper-button-disabled|disabled|forbidden)(?:\s|$)/.test(classes);
    if (!nextDisabled) {
      const box = intersection(control.getBoundingClientRect(), rootBox);
      if (box.width > 2 && box.height > 2) {
        const x = box.left + box.width / 2, y = box.top + box.height / 2, hit = document.elementFromPoint(x, y);
        if (hit && (control === hit || control.contains(hit))) next = { x, y };
      }
    }
  }
  const shown = picture.shown;
  const controlScope = root.closest('.note-container, .note-detail') || root;
  const controlSummary = [...controlScope.querySelectorAll('*')].filter(element => visible(element) && !element.closest(excluded) && (element.tagName === 'BUTTON' || /arrow|pagination|bullet|switch|next|prev|dot/.test(String(element.getAttribute('class') || '')))).slice(0, 30).map(element => {
    const box = element.getBoundingClientRect();
    return { tag: element.tagName, class: String(element.getAttribute('class') || '').slice(0, 160), label: String(element.getAttribute('aria-label') || element.getAttribute('title') || element.textContent || '').trim().slice(0, 80), x: Math.round(box.left), y: Math.round(box.top), width: Math.round(box.width), height: Math.round(box.height) };
  });
  const x = Math.ceil(shown.left), y = Math.ceil(shown.top);
  const clip = { x, y, width: Math.floor(shown.right) - x, height: Math.floor(shown.bottom) - y };
  if (clip.width < 120 || clip.height < 120) return { available: false, reason: '图片在当前视口中的可见面积不足。' };
  return {
    available: true, clip, fingerprint: picture.source, page, total, next, nextDisabled, controlSummary,
    visibleEnd: (page !== null && total !== null && page === total) || nextDisabled,
    cropped: shown.width + 2 < picture.box.width || shown.height + 2 < picture.box.height
  };
}

function pngDimensions(value) {
  const bytes = Buffer.from(value);
  if (bytes.length < 33 || bytes.length > MAX_PNG_BYTES || !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) || bytes.toString('ascii', 12, 16) !== 'IHDR') throw new Error('图片截图不是有效的有限 PNG');
  const width = bytes.readUInt32BE(16), height = bytes.readUInt32BE(20);
  if (!width || !height || width > 10000 || height > 10000) throw new Error('图片截图尺寸无效');
  return { width, height };
}

function savePNG(dataDir, value) {
  const bytes = Buffer.from(value), dimensions = pngDimensions(bytes);
  const id = crypto.createHash('sha256').update(bytes).digest('hex');
  const mediaRoot = path.join(path.resolve(dataDir), 'media');
  if (fs.existsSync(mediaRoot) && (!fs.lstatSync(mediaRoot).isDirectory() || fs.lstatSync(mediaRoot).isSymbolicLink())) throw new Error('图片目录必须是本机真实目录');
  fs.mkdirSync(mediaRoot, { recursive: true, mode: 0o700 });
  const file = path.join(mediaRoot, `${id}.png`);
  if (fs.existsSync(file)) {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size !== bytes.length || crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== id) throw new Error('已存在的图片文件不符合校验');
  } else {
    const temporary = path.join(mediaRoot, `.${id}.${crypto.randomUUID()}.tmp`);
    try { fs.writeFileSync(temporary, bytes, { flag: 'wx', mode: 0o600 }); fs.renameSync(temporary, file); }
    finally { try { fs.unlinkSync(temporary); } catch {} }
  }
  return { id, ...dimensions };
}

async function captureNoteImages(page, { dataDir, limit = 9, checkCancelled = () => {}, inspect = async () => {}, onImage = async () => {}, onDiagnostic = async () => {} } = {}) {
  if (!Number.isInteger(limit) || limit < 0 || limit > 18) throw new Error('图片上限须为 0–18 之间的整数');
  const images = [], seenSlides = new Set(), seenImages = new Set();
  let cropped = false;
  const result = (state, reason) => ({ images, imageCoverage: { state, reason, visibleCount: images.length } });
  if (!limit) return result('not_opened', '本轮图片采集已关闭或上限为 0。');
  for (let attempt = 0; attempt < limit; attempt++) {
    checkCancelled(); await inspect(page);
    let snapshot;
    try {
      snapshot = await page.evaluate(readVisibleGalleryDOM);
      // An already visible gallery can still be loading its first image. Wait
      // briefly within a fixed budget, rather than recording a placeholder.
      for (let retry = 0; !snapshot?.available && retry < 6; retry++) {
        await page.waitForTimeout(250); checkCancelled(); await inspect(page);
        snapshot = await page.evaluate(readVisibleGalleryDOM);
      }
    }
    catch { checkCancelled(); return result(images.length ? 'partial' : 'failed', '图片区域读取中断；已经保存的截图保留。'); }
    if (!snapshot?.available) return result(images.length ? 'partial' : 'failed', snapshot?.reason || '没有识别到可见的帖子图片。');
    if (!snapshot.fingerprint || seenSlides.has(snapshot.fingerprint)) return result('partial', '轮播图回到已经读取的图片，停止重复截图；未确认完整图片范围。');
    seenSlides.add(snapshot.fingerprint); cropped ||= !!snapshot.cropped;
    let saved;
    try {
      const bytes = await page.screenshot({ type: 'png', clip: snapshot.clip, animations: 'disabled', caret: 'hide', scale: 'css', timeout: 5000 });
      saved = savePNG(dataDir, bytes);
    } catch { checkCancelled(); return result(images.length ? 'partial' : 'failed', '可见图片截图保存失败；不会用链接或空图片代替。'); }
    if (!seenImages.has(saved.id)) {
      seenImages.add(saved.id);
      const image = { ...saved, page: snapshot.page || attempt + 1, kind: 'page_capture', mimeType: 'image/png', capturedAt: new Date().toISOString() };
      images.push(image);
      await onImage(image, { state: 'partial', reason: '图片正在采集；只保存实际显示的页面截图。', visibleCount: images.length });
    }
    if (snapshot.visibleEnd) return result(cropped ? 'partial' : 'visible_end', cropped ? '已看到图片轮播末尾，但部分图片超出当前视口，截图可能不完整。' : '已看到页面图片轮播末尾；保存的是页面截图，未取得原始分辨率文件。');
    if (attempt + 1 >= limit) return result('partial', '达到每帖图片数量上限，未确认全部图片。');
    checkCancelled(); await inspect(page);
    // Re-read after the screenshot so a stale/changed carousel cannot redirect
    // a coordinate click to an unrelated or destructive control.
    let fresh;
    try { fresh = await page.evaluate(readVisibleGalleryDOM); }
    catch { checkCancelled(); return result('partial', '轮播图读取中断，当前图片已保存。'); }
    if (fresh?.available && fresh.fingerprint === snapshot.fingerprint && !fresh.next && typeof page.mouse.move === 'function') {
      // Some gallery arrows appear only when the pointer is over the image.
      await page.mouse.move(snapshot.clip.x + snapshot.clip.width / 2, snapshot.clip.y + snapshot.clip.height / 2);
      await page.waitForTimeout(200); checkCancelled(); await inspect(page);
      fresh = await page.evaluate(readVisibleGalleryDOM);
    }
    if (fresh?.available && !fresh.next) {
      await onDiagnostic({ page: fresh.page, total: fresh.total, controls: fresh.controlSummary || [] });
      return result('partial', '未识别到唯一可点击的下一张图片控件；当前图片已保存。');
    }
    if (!fresh?.available || fresh.fingerprint !== snapshot.fingerprint || !fresh.next) return result('partial', '图片控件已变化，停止翻页；当前图片已保存。');
    try { await page.mouse.click(fresh.next.x, fresh.next.y); }
    catch { checkCancelled(); return result('partial', '下一张图片控件未能打开，当前图片已保存。'); }
    let changed = false;
    for (let retry = 0; retry < 6; retry++) {
      await page.waitForTimeout(250); checkCancelled(); await inspect(page);
      let current;
      try { current = await page.evaluate(readVisibleGalleryDOM); }
      catch { checkCancelled(); return result('partial', '图片翻页读取中断，当前图片已保存。'); }
      if (current?.available && current.fingerprint !== snapshot.fingerprint) { changed = true; break; }
    }
    if (!changed) return result('partial', '翻页后没有出现新的已加载图片，停止重复截图。');
  }
  return result('partial', '图片采集预算已用完。');
}

module.exports = { readVisibleGalleryDOM, pngDimensions, savePNG, captureNoteImages, MAX_PNG_BYTES };
