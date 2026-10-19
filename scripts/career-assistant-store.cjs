'use strict';
const { DatabaseSync } = require('node:sqlite');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const hash = value => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const fail = (message, status = 400) => Object.assign(new Error(message), { status });

class AssistantStore {
  constructor(directory) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    this.directory = directory;
    this.db = new DatabaseSync(path.join(directory, 'assistant.sqlite'));
    if (this.db.prepare('PRAGMA user_version').get().user_version > 1) { this.db.close(); throw fail('数据库版本较新，请使用新版服务', 409); }
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL CHECK(json_valid(body)), PRIMARY KEY(kind,id));
      CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY, at TEXT NOT NULL, action TEXT NOT NULL, entity TEXT NOT NULL);
      PRAGMA user_version=1;`);
  }
  get(kind, id) { const row = this.db.prepare('SELECT body FROM records WHERE kind=? AND id=?').get(kind, id); return row ? JSON.parse(row.body) : null; }
  list(kind) { return this.db.prepare('SELECT body FROM records WHERE kind=? ORDER BY id').all(kind).map(row => JSON.parse(row.body)); }
  put(kind, value) {
    if (!value || typeof value.id !== 'string' || !value.id || value.id.length > 200) throw fail('记录 ID 无效');
    this.db.prepare('INSERT INTO records VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body').run(kind, value.id, JSON.stringify(value));
    return value;
  }
  remove(kind, id) { this.db.prepare('DELETE FROM records WHERE kind=? AND id=?').run(kind, id); }
  transaction(fn) {
    if (this.inTransaction) return fn();
    this.db.exec('BEGIN IMMEDIATE');
    this.inTransaction = true;
    try { const result = fn(); this.db.exec('COMMIT'); return result; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
    finally { this.inTransaction = false; }
  }
  event(action, entity, at = new Date().toISOString()) { this.db.prepare('INSERT INTO events(at,action,entity) VALUES(?,?,?)').run(at, action, entity); }
  backup() {
    const dir = path.join(this.directory, 'backups'); fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const id = crypto.randomUUID();
    const file = path.join(dir, id + '.sqlite');
    // VACUUM INTO includes committed WAL contents in one self-contained snapshot.
    this.db.prepare('VACUUM INTO ?').run(file);
    return { id, filename: id + '.sqlite' };
  }
  export() { return { schemaVersion: 2, exportedAt: new Date().toISOString(), records: this.db.prepare('SELECT kind,id,body FROM records ORDER BY kind,id').all().map(r => ({ kind: r.kind, value: JSON.parse(r.body) })) }; }
  close() { this.db.close(); }
}
module.exports = { AssistantStore, hash, fail };
