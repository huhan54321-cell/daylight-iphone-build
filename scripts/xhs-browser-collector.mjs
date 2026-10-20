/** Read only the visible Xiaohongshu website after the owner's interactive login.
 * No private APIs, request signing, hidden app state, CAPTCHA solving or stealth.
 * This module is invoked by the local research service, never from a remote URL.
 */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { normalizeConfig, normalizeNote, mergeNotes } = require('./xhs-core.cjs');
const { xhsDocumentIssue, safeNoteURL, readSearchDOM, readNoteDOM, readCommentsDOM } = require('./xhs-browser-page.cjs');
const { ensureLoginDialog, saveLoginPreview } = require('./xhs-login-page.cjs');
const { normalizeKnownNoteIds, shouldContinueSearch, createCandidateSchedule } = require('./xhs-dedup.cjs');
const { captureNoteImages } = require('./xhs-note-images.cjs');
const { SCOPE, detailDecision } = require('./xhs-relevance.cjs');
const args = process.argv.slice(2);
const arg = name => { const index = args.indexOf(name); return index < 0 ? null : args[index + 1]; };
const mode = arg('--mode');
const dataDir = path.resolve(arg('--data-dir') || path.join(import.meta.dirname, '../data/xhs-private'));
const runDir = path.resolve(arg('--run-dir') || path.join(dataDir, 'manual-run'));
let config = {}, context, notes = [], imageUpdates = [], keywordMatches = [], candidateSchedule = null, cancelled = false;
const galleryDiagnostics = [];
const coverage = { partial: true, queries: [], detailsVisited: 0, commentsCount: 0, imagesCount: 0, searchOrder: '平台默认排序；未确认按发布时间排序', commentScope: '时间范围用于帖子，保留这些帖子下实际可见评论（评论日期单独记录）', imageScope: '仅保存页面实际显示的帖子图片截图；不下载原图、不自动识别图片文字。', startedAt: new Date().toISOString() };
let state = 'error', message = '任务未完成';
class CollectorError extends Error { constructor(state, message) { super(message); this.state = state; } }
function progress(phase, message) {
  process.stdout.write(JSON.stringify({ type: 'progress', phase, message, notesCount: notes.length, commentsCount: coverage.commentsCount, imagesCount: coverage.imagesCount }) + '\n');
}
function checkpoint() {
  if (candidateSchedule) { coverage.dedup = candidateSchedule.coverage(); keywordMatches = candidateSchedule.keywordMatches(); }
  coverage.imagesCount = notes.reduce((sum, note) => sum + (note.images?.length || 0), 0) + imageUpdates.reduce((sum, note) => sum + note.images.length, 0);
  fs.mkdirSync(runDir, { recursive: true, mode: 0o700 });
  const file = path.join(runDir, 'result.json');
  fs.writeFileSync(file + '.tmp', JSON.stringify({ state, message, notes, imageUpdates, keywordMatches, coverage, finishedAt: new Date().toISOString() }), { mode: 0o600 });
  fs.renameSync(file + '.tmp', file);
}
function checkCancelled() { if (cancelled) throw new CollectorError('cancelled', '已停止；已取得的部分数据保留。'); }
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { if (chunk.includes('cancel')) { cancelled = true; if (context) context.close().catch(() => {}); } });
async function inspect(page, allowLogin = false) {
  checkCancelled();
  const text = await page.locator('body').innerText({ timeout: 8000 });
  const issue = xhsDocumentIssue(page.url(), text.slice(0, 80000), { allowLogin });
  if (issue) throw new CollectorError(issue.state, issue.message);
  // Detect visible login/security overlays, without treating a post mentioning login as a gate.
  const gate = await page.locator('.login-container, .login-modal, .reds-login-container, .captcha-container, .verify-container').filter({ visible: true }).first().innerText({ timeout: 500 }).catch(() => '');
  if (gate && /安全验证|滑块|验证码|验证后继续/.test(gate) && !/扫码登录|手机号登录/.test(gate)) throw new CollectorError('blocked', '页面要求安全验证，采集已停止；请在浏览器自行处理后重新开始。');
  if (gate && !allowLogin) throw new CollectorError('login_required', '小红书要求登录，请先在本机浏览器扫码登录。');
  return text;
}
async function login(page) {
  await page.goto('https://www.xiaohongshu.com/explore', { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.bringToFront();
  fs.mkdirSync(runDir, { recursive: true, mode: 0o700 });
  progress('login', '正在加载小红书登录页；扫码页面会直接显示在研究入口中。');
  // Only the account control in the sidebar can confirm login. Authors on feed cards cannot.
  const start = Date.now();
  let dialogRequested = false, previewAt = 0, dialogAttemptAt = 0;
  while (Date.now() - start < 9 * 60 * 1000) {
    try { await inspect(page, true); }
    catch (error) {
      if (error.state === 'blocked' && new URL(page.url()).origin === 'https://www.xiaohongshu.com') {
        const temporary = path.join(runDir, 'login-preview.tmp.png');
        await saveLoginPreview(page, temporary);
        fs.renameSync(temporary, path.join(runDir, 'login-preview.png'));
        progress('blocked', '小红书当前要求安全验证，下面显示实际页面。需要本人在登录浏览器完成验证后才能出现二维码。');
        await page.waitForTimeout(1200); continue;
      }
      throw error;
    }
    const account = page.locator('.side-bar .user a[href*="/user/profile/"], .side-bar a.user[href*="/user/profile/"], .side-bar .user.side-bar-component, .sidebar a[href*="/user/profile/"], .user-side-bar a[href*="/user/profile/"]').filter({ visible: true });
    const modal = page.locator('.login-container, .login-modal, .reds-login-container').filter({ visible: true });
    if (await account.count() > 0 && await modal.count() === 0) {
      state = 'ok'; message = '已识别本机账号入口，登录会话保存在电脑；采集时会再次检查可访问状态。';
      progress('login_complete', message); return;
    }
    if (!dialogRequested && Date.now() - dialogAttemptAt >= 8000) {
      const result = await ensureLoginDialog(page);
      dialogRequested = result === 'visible';
      dialogAttemptAt = Date.now();
    }
    if (Date.now() - previewAt >= 3000) {
      const temporary = path.join(runDir, 'login-preview.tmp.png');
      await saveLoginPreview(page, temporary);
      fs.renameSync(temporary, path.join(runDir, 'login-preview.png'));
      previewAt = Date.now();
      progress('login', '小红书当前登录页面已显示在研究入口中，请用手机小红书扫一扫；二维码到期时图片会随网页更新。');
    }
    await page.waitForTimeout(1200);
  }
  throw new CollectorError('login_required', '等待扫码登录超时，或未能确认账号入口。请重新登录；不会把未确认状态当作成功。');
}
async function scrollSearch(page) {
  await page.evaluate(() => window.scrollBy(0, Math.round(window.innerHeight * 0.85)));
  await page.waitForTimeout(1000);
}
async function collectComments(page, raw) {
  const limit = config.maxCommentsPerNote;
  raw.comments = [];
  raw.commentCoverage = { state: 'not_opened', reason: limit ? '尚未读取' : '本轮评论上限为0', displayedTotal: null, visibleCount: 0 };
  if (!limit) return;
  const seen = new Map();
  let visibleEnd = false, total = null, stagnant = 0;
  for (let round = 0; round <= config.maxCommentScrolls; round++) {
    await inspect(page);
    const snapshot = await page.evaluate(readCommentsDOM);
    total = snapshot.displayedTotal ?? total;
    const before = seen.size;
    for (const comment of snapshot.comments) {
      if (!comment.text) continue;
      const key = comment.id || JSON.stringify([comment.parentId, comment.text, comment.dateText]);
      if (!seen.has(key) && seen.size < limit) seen.set(key, comment);
    }
    visibleEnd = !!snapshot.visibleEnd;
    raw.comments = [...seen.values()];
    if (seen.size >= limit || visibleEnd || round === config.maxCommentScrolls) break;
    stagnant = seen.size === before ? stagnant + 1 : 0;
    // Expands only reply controls within the comments area; never likes/posts/replies.
    const expand = page.locator('.comments-container .show-more, .comments-container .show-more-replies, .comments-container .reply-more, .comments-container .more-replies').filter({ visible: true }).first();
    if (await expand.isVisible().catch(() => false)) await expand.click({ timeout: 1500 }).catch(() => {});
    const scrolled = await page.evaluate(() => {
      const candidates = [...document.querySelectorAll('.comments-container, .note-scroller, .note-container .right-container, .note-detail .right-container')];
      const target = candidates.find(el => el.scrollHeight > el.clientHeight + 10 && el.clientHeight > 50);
      if (!target) return false;
      target.scrollTop += Math.round(target.clientHeight * 0.85); return true;
    });
    if (!scrolled || stagnant >= 2) break;
    await page.waitForTimeout(900);
  }
  raw.commentCoverage = {
    state: visibleEnd && (total === null || seen.size >= total) ? 'visible_end' : 'partial',
    displayedTotal: total, visibleCount: raw.comments.length,
    reason: visibleEnd ? '已看到页面底部；折叠回复和不可见评论可能仍缺失。' : seen.size >= limit ? '达到本轮评论数量上限，未取得全部评论。' : '达到页面滚动预算或没有新可见内容；未取得全部评论。'
  };
}
async function collectImages(page, raw, save) {
  raw.images = [];
  raw.imageCoverage = { state: 'not_opened', reason: '尚未读取图片', visibleCount: 0 };
  const result = await captureNoteImages(page, {
    dataDir, limit: config.collectImages ? config.maxImagesPerNote : 0, checkCancelled, inspect,
    onDiagnostic: async diagnostic => {
      galleryDiagnostics.push({ id: raw.id, ...diagnostic });
      const file = path.join(runDir, 'gallery-diagnostics.json');
      fs.writeFileSync(file + '.tmp', JSON.stringify(galleryDiagnostics.slice(-100)), { mode: 0o600 });
      fs.renameSync(file + '.tmp', file);
    },
    onImage: async (image, imageCoverage) => {
      raw.images.push(image); raw.imageCoverage = imageCoverage;
      save(); checkpoint();
      progress('images', `已保存${coverage.imagesCount}张实际可见的帖子图片截图。`);
    }
  });
  raw.images = result.images; raw.imageCoverage = result.imageCoverage;
  save(); checkpoint();
}
async function enrichImages(page) {
  progress('images', `开始为${config.imageNotes.length}条已入库帖子补采简历或其他图片；不会重复搜索或生成新的帖子记录。`);
  for (const candidate of config.imageNotes) {
    checkCancelled(); coverage.detailsVisited++;
    progress('images', `正在补采第${coverage.detailsVisited}/${config.imageNotes.length}条已入库帖子的图片。`);
    await page.goto(candidate.url, { waitUntil: 'domcontentloaded', timeout: 25000 });
    await inspect(page);
    const opened = safeNoteURL(page.url());
    if (!opened || opened.id !== candidate.id) {
      imageUpdates.push({ id: candidate.id, images: [], imageCoverage: { state: 'failed', reason: '原帖跳转后未能确认对应帖子，未保存其他页面图片。', visibleCount: 0 } });
      checkpoint(); continue;
    }
    await page.locator('.note-container .media-container, .note-detail .media-container, .note-container .swiper, .note-detail .swiper, .note-container .note-slider, .note-detail .note-slider').first().waitFor({ state: 'visible', timeout: 7000 }).catch(() => {});
    await inspect(page);
    const update = { id: candidate.id, images: [], imageCoverage: { state: 'not_opened', reason: '尚未读取图片', visibleCount: 0 } };
    imageUpdates.push(update); checkpoint();
    await collectImages(page, update, () => {});
    await page.waitForTimeout(1000);
  }
  coverage.finishedAt = new Date().toISOString(); state = 'ok';
  message = `已回查${coverage.detailsVisited}条已入库帖子，保存${coverage.imagesCount}张可见图片截图；没有识别到的图片和未完成范围在报告中注明。`;
  progress('complete', message);
}
async function collect(page) {
  progress('search', '开始读取小红书搜索结果；只采集页面实际显示的内容。');
  // Establish the signed-in site's normal entry page before deep-linking to
  // search. A cold search navigation can stall in the site's redirect chain.
  await page.goto('https://www.xiaohongshu.com/explore', { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.locator('.side-bar, .sidebar, .login-container, section.note-item, .note-item').first().waitFor({ state: 'visible', timeout: 8000 }).catch(() => {});
  await inspect(page);
  candidateSchedule = createCandidateSchedule(config.excludeNoteIds, config);
  if (config.researchScope === SCOPE) coverage.relevance = { version: 1, strategy: '招聘、面经、实习分享轮转；补充材料至多20%，模糊标题至多10%（至少1条）；不以查询词、点赞或评论判定主题。', skippedExtras: 0, reviewedDetails: 0 };
  coverage.dedup = candidateSchedule.coverage();
  // Search every requested keyword before reading details, so early keywords do not consume the whole budget.
  for (const keyword of config.keywords) {
    checkCancelled();
    const query = { keyword, state: 'running', searchScrolls: 0, candidateCount: 0, skippedKnownNotes: 0, unseenCandidateCount: 0, detailsVisited: 0 };
    coverage.queries.push(query);
    const url = new URL('https://www.xiaohongshu.com/search_result');
    url.searchParams.set('keyword', keyword); url.searchParams.set('source', 'web_search_result_notes');
    await page.goto(url.href, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await inspect(page);
    await page.locator('section.note-item, .note-item, a[href*="/explore/"]').first().waitFor({ state: 'visible', timeout: 8000 }).catch(() => {});
    let unchanged = 0;
    for (let round = 0; round < config.maxSearchScrolls; round++) {
      const body = await inspect(page);
      const cards = await page.evaluate(readSearchDOM);
      const found = candidateSchedule.addCards(keyword, cards);
      query.searchScrolls++;
      Object.assign(query, candidateSchedule.stats(keyword));
      progress('search', `关键词“${keyword}”：已读取${query.searchScrolls}轮结果，跳过${query.skippedKnownNotes}条已入库帖子，发现${query.unseenCandidateCount}条未入库链接。`);
      unchanged = found.newlySeenNotes === 0 ? unchanged + 1 : 0;
      // Repeated known posts at the top cannot consume the discovery quota.
      // Until fresh cards appear, keep scrolling within the original budget.
      if (!shouldContinueSearch(query, { round, maxSearchScrolls: config.maxSearchScrolls, targetUnseen: Math.ceil(config.maxNotes / config.keywords.length) * 4, unchanged, noResults: /没有找到相关|暂无搜索结果/.test(body) })) break;
      if (round + 1 < config.maxSearchScrolls) await scrollSearch(page);
    }
    query.state = query.candidateCount ? 'sampled' : 'empty_or_unavailable';
    query.reason = '有界搜索样本；没有验证全站和全部分页。';
    checkpoint();
  }
  // Round-robin detail visits across disjoint query pools.
  const ordered = candidateSchedule.plan(config.maxNotes);
  if (coverage.relevance) coverage.relevance.planned = ordered.reduce((counts, card) => { const key = card.relevance?.label || '待核查'; counts[key] = (counts[key] || 0) + 1; return counts; }, {});
  checkpoint();
  for (const candidate of ordered) {
    checkCancelled();
    const id = candidate.id;
    candidateSchedule.recordAttempt(id);
    coverage.detailsVisited++;
    for (const query of coverage.queries) if (candidate.keywords.includes(query.keyword)) query.detailsVisited++;
    progress('details', `正在读取第${coverage.detailsVisited}/${ordered.length}条帖子的标题与正文${config.collectImages ? '、图片' : ''}${config.maxCommentsPerNote ? '、评论' : ''}。`);
    await page.goto(candidate.url, { waitUntil: 'domcontentloaded', timeout: 25000 });
    await inspect(page);
    await page.locator('#detail-desc, .note-content, .note-container .desc').first().waitFor({ state: 'visible', timeout: 7000 }).catch(() => {});
    await inspect(page);
    const raw = { ...await page.evaluate(readNoteDOM), id, url: candidate.url, keywords: candidate.keywords, collectedAt: new Date().toISOString() };
    raw.title = raw.title || candidate.title;
    raw.commentCoverage = { state: 'not_opened', reason: '尚未读取评论' };
    const decision = detailDecision(normalizeNote(raw), config);
    if (coverage.relevance) coverage.relevance.reviewedDetails++;
    if (!decision.collectExtras) {
      raw.commentCoverage = { state: 'not_opened', reason: decision.reason + '，跳过评论采集' };
      raw.imageCoverage = { state: 'not_opened', reason: decision.reason + '，跳过图片采集' };
      // Keep readable prose in history for ID dedup and later scope changes.
      if (raw.text) notes = mergeNotes(notes, [normalizeNote(raw)]);
      coverage.relevance.skippedExtras++;
      checkpoint(); continue;
    }
    // Persist prose before gallery traversal, and persist every captured image
    // so cancellation never discards an actual screenshot already saved.
    if (raw.text || raw.title && !config.collectImages) { notes = mergeNotes(notes, [normalizeNote(raw)]); checkpoint(); }
    await collectImages(page, raw, () => {
      if (raw.text || raw.images.length) notes = mergeNotes(notes, [normalizeNote(raw)]);
    });
    if (!raw.text && !raw.images.length && !(raw.title && !config.collectImages)) {
      coverage.unreadableDetails = (coverage.unreadableDetails || 0) + 1;
      coverage.failedDetails = [...(coverage.failedDetails || []), { id, reason: '没有读取到可见正文或保存到帖子图片，可能是视频、访问受限、加载失败或页面结构变化。' }];
      checkpoint(); continue;
    }
    // Image-only posts are retained as image evidence with empty text; they are
    // not turned into fabricated OCR/prose or given a guessed date.
    notes = mergeNotes(notes, [normalizeNote(raw)]); checkpoint();
    try { await collectComments(page, raw); }
    catch (error) {
      raw.commentCoverage = { state: 'failed', visibleCount: raw.comments?.length || 0, reason: '评论读取中断；已取得的评论保留。' };
      notes = mergeNotes(notes, [normalizeNote(raw)]); checkpoint(); throw error;
    }
    notes = mergeNotes(notes, [normalizeNote(raw)]);
    coverage.commentsCount = notes.reduce((sum, note) => sum + note.comments.length, 0);
    checkpoint();
    await page.waitForTimeout(1200);
  }
  if (!notes.length && !ordered.length && config.researchScope === SCOPE) {
    coverage.finishedAt = new Date().toISOString(); state = 'ok';
    message = `本轮有限搜索范围内未发现值得打开的新实习材料；已存帖子跳过，未相关或弱相关搜索卡片未凑数采集。`;
    progress('complete', message); return;
  }
  if (!notes.length && !ordered.length && candidateSchedule.keywordMatches().length) {
    coverage.finishedAt = new Date().toISOString(); state = 'ok';
    message = `本轮搜索发现的${candidateSchedule.coverage().skippedKnownNotes}条帖子均已入库，已跳过详情访问；有限搜索范围内没有新增帖子。`;
    progress('complete', message); return;
  }
  if (!notes.length) throw new CollectorError('error', '未取得可用的新帖子正文或图片。可能需要登录、网页访问受限、没有新匹配结果或页面结构变化；已有报告保留。');
  coverage.finishedAt = new Date().toISOString();
  state = 'ok'; message = `已取得${notes.length}条新的正文或图片帖子、${coverage.commentsCount}条可见评论、${coverage.imagesCount}张图片截图，跳过${candidateSchedule.coverage().skippedKnownNotes}条已入库帖子；发布日期按 ${config.startDate} 至 ${config.endDate} 核对，未知日期单列。`;
  progress('complete', message);
}
async function recheck(page) {
  for (const candidate of config.recheckNotes) {
    checkCancelled(); coverage.detailsVisited++;
    await page.goto(candidate.url, { waitUntil: 'domcontentloaded', timeout: 25000 });
    await inspect(page);
    if (safeNoteURL(page.url())?.id !== candidate.id) { coverage.unreadableDetails = (coverage.unreadableDetails || 0) + 1; continue; }
    await page.locator('#detail-desc, .note-content, .note-container .desc').first().waitFor({ state: 'visible', timeout: 7000 }).catch(() => {});
    const raw = { ...await page.evaluate(readNoteDOM), id: candidate.id, url: candidate.url, collectedAt: new Date().toISOString(), keywords: config.keywords };
    if (raw.text) notes.push(normalizeNote(raw));
    else coverage.unreadableDetails = (coverage.unreadableDetails || 0) + 1;
    checkpoint(); progress('recheck', `已复查 ${coverage.detailsVisited}/${config.recheckNotes.length} 条收藏招聘帖`);
  }
  state = 'ok'; coverage.finishedAt = new Date().toISOString();
  message = '收藏招聘帖复查完成；未取得正文的帖子保留旧内容，不推断已关闭。';
}
try {
  if (!['login', 'collect', 'enrich-images', 'recheck'].includes(mode)) throw new Error('指定有效的采集模式。');
  config = JSON.parse(fs.readFileSync(arg('--config'), 'utf8'));
  if (mode !== 'login') {
    const excludeNoteIds = normalizeKnownNoteIds(config.excludeNoteIds);
    const rawImageNotes = config.imageNotes;
    const rawRecheckNotes = config.recheckNotes;
    config = { ...normalizeConfig(config), excludeNoteIds };
    if (mode === 'recheck') {
      if (!Array.isArray(rawRecheckNotes) || !rawRecheckNotes.length || rawRecheckNotes.length > 10) throw new Error('每轮复查 1–10 条收藏帖子');
      config.recheckNotes = rawRecheckNotes.map(candidate => {
        const note = safeNoteURL(candidate?.url);
        if (!note || note.id !== candidate.id) throw new Error('复查链接与帖子 ID 不匹配');
        return note;
      });
    }
    if (mode === 'enrich-images') {
      if (!Array.isArray(rawImageNotes) || !rawImageNotes.length || rawImageNotes.length > 100) throw new Error('图片回查须提供 1–100 条已入库帖子。');
      const seen = new Set();
      config.imageNotes = rawImageNotes.flatMap(candidate => {
        const note = safeNoteURL(candidate?.url);
        if (!note || candidate.id !== note.id) throw new Error('图片回查帖子必须包含匹配 ID 的小红书 HTTPS 官网链接。');
        if (seen.has(note.id)) return [];
        seen.add(note.id); return [{ ...note, title: String(candidate.title || '').slice(0, 500) }];
      });
    }
  }
  if (!config.maxCommentsPerNote) coverage.commentScope = '本轮不读取评论。';
  if (!config.collectImages) coverage.imageScope = '本轮读取标题和正文，不保存图片；图片中的招聘条件尚未识别。';
  const browserChannel = config.browserChannel || 'msedge';
  if (!['msedge', 'chrome', 'chromium'].includes(browserChannel)) throw new Error('浏览器选择无效。');
  const profile = path.join(dataDir, `browser-xhs-${browserChannel}`);
  if (mode !== 'login' && !fs.existsSync(profile)) throw new CollectorError('login_required', '尚无所选浏览器的本机登录会话，请先扫码登录。');
  let chromium;
  try { ({ chromium } = await import('playwright')); }
  catch { throw new Error('未安装 Playwright，请在项目中运行 npm install --no-save --package-lock=false playwright；Edge模式无需下载Chromium。'); }
  fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(dataDir, '.gitignore'), '*\n', { mode: 0o600 });
  try {
    context = await chromium.launchPersistentContext(profile, { headless: false, ...(browserChannel !== 'chromium' ? { channel: browserChannel } : {}), viewport: { width: 1280, height: 900 } });
  } catch { throw new Error('无法打开所选浏览器。请关闭上次采集窗口，确认已安装Edge/Chrome，或按说明安装Chromium。'); }
  context.setDefaultTimeout(5000);
  // Do not navigate Edge's startup/restored tab: its pending startup navigation
  // can replace the collector URL with about:blank after goto has resolved.
  const page = await context.newPage();
  if (mode === 'login') await login(page);
  else if (mode === 'recheck') await recheck(page);
  else if (mode === 'enrich-images') await enrichImages(page);
  else await collect(page);
} catch (error) {
  state = cancelled ? 'cancelled' : error.state || 'error';
  // Do not publish browser error stacks, URLs with tokens, or a browser profile's contents.
  message = cancelled ? '已停止；已取得的部分数据保留。' : error instanceof CollectorError || !context ? error.message :
    error.name === 'TimeoutError' ? '等待页面加载或可见内容超时；已有内容保留，本轮未完成，不能视为没有相关招聘。' :
    '页面读取失败或浏览器已关闭；已取得的部分内容保留。';
  progress(state, message);
  process.exitCode = state === 'cancelled' ? 0 : 1;
} finally {
  coverage.commentsCount = notes.reduce((sum, note) => sum + note.comments.length, 0);
  coverage.finishedAt = new Date().toISOString();
  for (const query of coverage.queries) if (query.state === 'running') {
    query.state = 'interrupted'; query.reason = message;
  }
  checkpoint();
  if (context) await context.close().catch(() => {});
  process.stdin.pause();
}
