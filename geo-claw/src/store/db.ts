import Database from 'better-sqlite3';
import type { Database as BetterSqliteDatabase } from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { paths } from '../config.js';

fs.mkdirSync(path.dirname(paths.dbFile), { recursive: true });

export const db: BetterSqliteDatabase = new Database(paths.dbFile);
db.pragma('journal_mode = WAL');
db.pragma('synchronous = NORMAL');

db.exec(`
CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  channel_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_conv_channel_ts ON conversations(channel_id, ts);

CREATE TABLE IF NOT EXISTS kv (
  k TEXT PRIMARY KEY,
  v TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS conversations_fts USING fts5(
  channel_id UNINDEXED,
  content,
  content='conversations',
  content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS conversations_ai AFTER INSERT ON conversations BEGIN
  INSERT INTO conversations_fts(rowid, channel_id, content) VALUES (new.id, new.channel_id, new.content);
END;

CREATE TRIGGER IF NOT EXISTS conversations_ad AFTER DELETE ON conversations BEGIN
  INSERT INTO conversations_fts(conversations_fts, rowid, channel_id, content)
    VALUES('delete', old.id, old.channel_id, old.content);
END;

CREATE TRIGGER IF NOT EXISTS conversations_au AFTER UPDATE OF content ON conversations BEGIN
  INSERT INTO conversations_fts(conversations_fts, rowid, channel_id, content)
    VALUES('delete', old.id, old.channel_id, old.content);
  INSERT INTO conversations_fts(rowid, channel_id, content)
    VALUES (new.id, new.channel_id, new.content);
END;
`);

// Backfill FTS for rows that pre-date the virtual table.
const ftsCount = (db.prepare('SELECT COUNT(*) AS n FROM conversations_fts').get() as { n: number }).n;
const convCount = (db.prepare('SELECT COUNT(*) AS n FROM conversations').get() as { n: number }).n;
if (ftsCount < convCount) {
  db.exec(`
    INSERT INTO conversations_fts(rowid, channel_id, content)
      SELECT id, channel_id, content FROM conversations
      WHERE id NOT IN (SELECT rowid FROM conversations_fts);
  `);
}

export type Role = 'user' | 'assistant';

export type ConversationRow = {
  id: number;
  channel_id: string;
  role: Role;
  content: string;
  ts: number;
};

const stmtAppend = db.prepare(
  'INSERT INTO conversations (channel_id, role, content, ts) VALUES (?, ?, ?, ?)',
);
const stmtLoad = db.prepare(
  'SELECT id, channel_id, role, content, ts FROM conversations WHERE channel_id = ? ORDER BY ts DESC LIMIT ?',
);
const stmtCount = db.prepare(
  'SELECT COUNT(*) AS n FROM conversations WHERE channel_id = ?',
);
const stmtPrune = db.prepare(`
  DELETE FROM conversations
  WHERE id IN (
    SELECT id FROM conversations
    WHERE channel_id = ?
    ORDER BY ts ASC
    LIMIT ?
  )
`);
const stmtListChannels = db.prepare(`
  SELECT channel_id, MAX(ts) AS last_ts, COUNT(*) AS msg_count
  FROM conversations
  WHERE channel_id LIKE ?
  GROUP BY channel_id
  ORDER BY last_ts DESC
  LIMIT ?
`);
const stmtKvGet = db.prepare('SELECT v FROM kv WHERE k = ?');
const stmtKvSet = db.prepare(
  'INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v',
);

export function appendMessage(channelId: string, role: Role, contentJson: string): void {
  stmtAppend.run(channelId, role, contentJson, Date.now());
}

const stmtClearChannel = db.prepare(
  'DELETE FROM conversations WHERE channel_id = ?',
);

export function clearChannel(channelId: string): number {
  const info = stmtClearChannel.run(channelId);
  return info.changes;
}

export function loadHistory(channelId: string, limit = 20): ConversationRow[] {
  const rows = stmtLoad.all(channelId, limit) as ConversationRow[];
  return rows.reverse();
}

export function countMessages(channelId: string): number {
  const row = stmtCount.get(channelId) as { n: number };
  return row.n;
}

export function listChannels(
  prefix = '',
  limit = 50,
): Array<{ channelId: string; lastTs: number; msgCount: number }> {
  const pattern = prefix ? `${prefix}%` : '%';
  const rows = stmtListChannels.all(pattern, limit) as Array<{
    channel_id: string;
    last_ts: number;
    msg_count: number;
  }>;
  return rows.map((r) => ({
    channelId: r.channel_id,
    lastTs: r.last_ts,
    msgCount: r.msg_count,
  }));
}

export function pruneOldest(channelId: string, n: number): number {
  const result = stmtPrune.run(channelId, n);
  return Number(result.changes ?? 0);
}

export type RecallRow = {
  channelId: string;
  role: Role;
  content: string;
  ts: number;
  snippet: string;
};

const stmtRecall = db.prepare(`
  SELECT c.channel_id, c.role, c.content, c.ts,
         snippet(conversations_fts, 1, '<<', '>>', '…', 16) AS snippet
  FROM conversations_fts
  JOIN conversations c ON c.id = conversations_fts.rowid
  WHERE conversations_fts MATCH ?
  ORDER BY rank
  LIMIT ?
`);

function buildFtsQuery(raw: string): string {
  const tokens = raw
    .split(/\s+/)
    .map((t) => t.replace(/[^\p{L}\p{N}_]/gu, ''))
    .filter((t) => t.length > 0)
    .map((t) => `"${t}"`);
  if (tokens.length === 0) return '';
  return tokens.join(' OR ');
}

export function recall(query: string, limit = 10): RecallRow[] {
  const fts = buildFtsQuery(query);
  if (fts.length === 0) return [];
  let rows: Array<{ channel_id: string; role: Role; content: string; ts: number; snippet: string }>;
  try {
    rows = stmtRecall.all(fts, limit) as typeof rows;
  } catch {
    return [];
  }
  return rows.map((r) => ({
    channelId: r.channel_id,
    role: r.role,
    content: r.content,
    ts: r.ts,
    snippet: r.snippet,
  }));
}

export function kvGet(k: string): string | null {
  const row = stmtKvGet.get(k) as { v: string } | undefined;
  return row?.v ?? null;
}

export function kvSet(k: string, v: string): void {
  stmtKvSet.run(k, v);
}

let closed = false;

export function closeDb(): void {
  if (closed) return;
  closed = true;
  try {
    db.close();
  } catch {
  }
}
