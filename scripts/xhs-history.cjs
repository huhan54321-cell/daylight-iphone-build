'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { mergeNotes, normalizeNote } = require('./xhs-core.cjs');
const MAX_HISTORY_BYTES = 24 * 1024 * 1024;

function datasetNotes(dataset) {
  return [...(dataset?.notes || []), ...(dataset?.undatedNotes || []), ...(dataset?.excludedNotes || [])];
}
function key(word) { return String(word || '').trim().replace(/\s+/g, ' ').toLowerCase(); }
function notesForConfig(notes, config) {
  const keywords = new Set(config.keywords.map(key));
  return notes.filter(note => note.keywords.some(word => keywords.has(key(word))));
}
function mergeHistory(existing, config, incoming = [], matches = []) {
  const tagged = incoming.map(raw => ({ ...raw, keywords: Array.isArray(raw.keywords) && raw.keywords.length ? raw.keywords : config.keywords }));
  const notes = mergeNotes(existing, tagged);
  const byID = new Map(notes.map(note => [note.id, note]));
  const permittedKeywords = new Set(config.keywords.map(key));
  for (const match of (Array.isArray(matches) ? matches : []).slice(0, 10000)) {
    const id = typeof match?.id === 'string' ? match.id.toLowerCase() : '';
    const prior = byID.get(id);
    if (!prior) continue; // Search cards are never accepted as newly captured evidence.
    const words = (Array.isArray(match.keywords) ? match.keywords : []).filter(word => typeof word === 'string' && permittedKeywords.has(key(word)));
    if (!words.length) continue;
    // Preserve the actual detail observation's time, text, dates and comment coverage.
    prior.keywords = [...new Set([...prior.keywords, ...words])].slice(0, 1000);
  }
  return notes;
}
function mergeImageUpdates(existing, updates = []) {
  const notes = mergeNotes([], existing);
  const byID = new Map(notes.map(note => [note.id, note]));
  for (const update of (Array.isArray(updates) ? updates : []).slice(0, 10000)) {
    const id = typeof update?.id === 'string' ? update.id.toLowerCase() : '';
    const prior = byID.get(id);
    // An enrichment checkpoint cannot create a post or turn a search card into
    // captured evidence. Its body, dates, keywords and observation time always
    // come from the already captured detail record.
    if (!prior || (!prior.text && !prior.images.length)) continue;
    try {
      const imageOnly = normalizeNote({ ...prior, images: update.images, imageCoverage: update.imageCoverage });
      byID.set(id, mergeNotes([prior], [imageOnly])[0]);
    } catch { /* A bad image update must not discard other valid checkpoints. */ }
  }
  return notes.map(note => byID.get(note.id));
}
function historyJSON(notes, savedAt) {
  const value = JSON.stringify({ schemaVersion: 1, savedAt, notes: mergeNotes([], notes) }, null, 2) + '\n';
  if (Buffer.byteLength(value) > MAX_HISTORY_BYTES) throw new Error('本机历史资料达到 24 MB 上限；已有资料保留，请先导出备份。');
  return value;
}
function readJSON(file) {
  const info = fs.lstatSync(file);
  if (info.isSymbolicLink() || !info.isFile() || info.size > MAX_HISTORY_BYTES) throw new Error('本地历史资料文件无效或过大；原文件已保留。');
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}
function loadHistory(dataDir, snapshots = []) {
  const file = path.join(dataDir, 'history.json');
  let notes = [];
  if (fs.existsSync(file)) {
    const saved = readJSON(file);
    if (saved.schemaVersion !== 1 || !Array.isArray(saved.notes)) throw new Error('本地历史资料格式无效；原文件已保留。');
    notes = mergeNotes([], saved.notes);
  }
  for (const snapshot of snapshots.filter(Boolean)) notes = mergeHistory(notes, snapshot.dataset.config, datasetNotes(snapshot.dataset));
  // Migrate earlier runs and recover checkpoints saved after an interrupted service.
  // Only fixed collection JSON paths are read, never browser profiles or account data.
  const runsRoot = path.join(dataDir, 'runs');
  const recoveredMatches = [];
  const recoveredImages = [];
  if (fs.existsSync(runsRoot) && !fs.lstatSync(runsRoot).isSymbolicLink()) {
    const entries = fs.readdirSync(runsRoot, { withFileTypes: true }).filter(entry => entry.isDirectory() && !entry.isSymbolicLink()).sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const runRoot = path.join(runsRoot, entry.name), resultFile = path.join(runRoot, 'result.json');
      if (!fs.existsSync(resultFile)) continue;
      try {
        const result = readJSON(resultFile);
        const rawNotes = Array.isArray(result.notes) ? result.notes : [];
        const imageUpdates = Array.isArray(result.imageUpdates) ? result.imageUpdates : [];
        if (!rawNotes.length && !result.keywordMatches?.length && !imageUpdates.length) continue;
        const runConfig = readJSON(path.join(runRoot, 'config.json'));
        if (!Array.isArray(runConfig.keywords) || !runConfig.keywords.length) continue;
        // Individual invalid records must not suppress the rest of a recoverable run.
        const readable = rawNotes.flatMap(raw => { try { const note = normalizeNote(raw); return note.text || note.images.length ? [note] : []; } catch { return []; } });
        notes = mergeHistory(notes, runConfig, readable);
        if (Array.isArray(result.keywordMatches)) recoveredMatches.push({ config: runConfig, matches: result.keywordMatches });
        if (imageUpdates.length) recoveredImages.push(imageUpdates);
      } catch { /* Bad checkpoints stay on disk; saved reports still migrate above. */ }
    }
  }
  // UUID directory order need not be collection order. Attribute known-only
  // searches after all recovered captures have been merged into the corpus.
  for (const recovered of recoveredMatches) notes = mergeHistory(notes, recovered.config, [], recovered.matches);
  // Image enrichment can also sort before the original detail capture. Keep it
  // separate until every real post has been recovered, and merge by page/time
  // rather than treating an enrichment timestamp as a new body observation.
  for (const updates of recoveredImages) notes = mergeImageUpdates(notes, updates);
  historyJSON(notes, new Date().toISOString()); // Fail explicitly instead of silently dropping old IDs.
  return notes;
}

module.exports = { datasetNotes, notesForConfig, mergeHistory, mergeImageUpdates, historyJSON, loadHistory };
