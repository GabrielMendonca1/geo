import { makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion, DisconnectReason, downloadContentFromMessage } from '@whiskeysockets/baileys';
import qrcode from 'qrcode-terminal';
import pino from 'pino';
import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, writeFileSync, readFileSync, existsSync, unlinkSync, readdirSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';

const HERMES_HOME = join(homedir(), '.hermes');
const ING_DIR = join(HERMES_HOME, 'whatsapp-ingest');
const AUTH_DIR = join(ING_DIR, 'auth');
const JSONL_PATH = join(HERMES_HOME, 'wa_ingest.jsonl');
const STATUS_PATH = join(ING_DIR, 'ingest-status.json');
const LOCK_PATH = join(ING_DIR, 'ingest.lock');
const QR_PATH = join(ING_DIR, 'last-qr.txt');
const MEDIA_DIR = join(HERMES_HOME, 'wa_media');
const HERMES_PY = join(HERMES_HOME, 'hermes-agent', 'venv', 'bin', 'python');
const HERMES_DIR = join(HERMES_HOME, 'hermes-agent');

const RECONNECT_ALERT_AFTER = 5;
const MAX_BACKOFF_MS = 60000;
const MEDIA_MAX_BYTES = 20 * 1024 * 1024;
const MEDIA_DL_TIMEOUT_MS = 15000;
const MEDIA_PRUNE_DAYS = 60;
const MEDIA_KINDS = new Set(['image', 'audio', 'document']);

mkdirSync(dirname(JSONL_PATH), { recursive: true });
mkdirSync(AUTH_DIR, { recursive: true });
mkdirSync(MEDIA_DIR, { recursive: true });

const log = pino({ level: process.env.HERMES_INGEST_LOG_LEVEL || 'info' });

const status = {
  pid: process.pid,
  state: 'starting',
  last_connect: null,
  last_msg: null,
  msg_count: 0,
  reconnects: 0,
  attempt: 0,
  alerted: false,
  updated_at: null,
};

function persist() {
  status.updated_at = new Date().toISOString();
  try { writeFileSync(STATUS_PATH, JSON.stringify(status, null, 2)); } catch {}
}

function notify(text) {
  return new Promise((resolve) => {
    try {
      const p = spawn(HERMES_PY, ['-m', 'hermes_cli.main', 'send', '--to', 'telegram', '--quiet', text], {
        cwd: HERMES_DIR,
        stdio: 'ignore',
      });
      const timer = setTimeout(() => { try { p.kill('SIGKILL'); } catch {} resolve(false); }, 20000);
      p.on('exit', () => { clearTimeout(timer); resolve(true); });
      p.on('error', () => { clearTimeout(timer); resolve(false); });
    } catch { resolve(false); }
  });
}

function acquireLock() {
  try {
    if (existsSync(LOCK_PATH)) {
      const prev = parseInt(readFileSync(LOCK_PATH, 'utf8').trim(), 10);
      if (prev && prev !== process.pid) {
        try { process.kill(prev, 0); return false; } catch {}
      }
    }
    writeFileSync(LOCK_PATH, String(process.pid));
    return true;
  } catch { return true; }
}

function extractText(msg) {
  const m = msg?.message;
  if (!m) return '';
  return (
    m.conversation ||
    m.extendedTextMessage?.text ||
    m.imageMessage?.caption ||
    m.videoMessage?.caption ||
    m.documentMessage?.caption ||
    m.buttonsResponseMessage?.selectedDisplayText ||
    m.listResponseMessage?.title ||
    ''
  );
}

function classify(msg) {
  const m = msg?.message;
  if (!m) return 'unknown';
  if (m.conversation || m.extendedTextMessage) return 'text';
  if (m.imageMessage) return 'image';
  if (m.videoMessage) return 'video';
  if (m.audioMessage) return 'audio';
  if (m.documentMessage) return 'document';
  if (m.stickerMessage) return 'sticker';
  if (m.contactMessage) return 'contact';
  if (m.locationMessage) return 'location';
  if (m.reactionMessage) return 'reaction';
  return 'other';
}

function mediaNodeFor(msg) {
  const m = msg?.message;
  if (!m) return null;
  if (m.imageMessage) return { kind: 'image', node: m.imageMessage };
  if (m.audioMessage) return { kind: 'audio', node: m.audioMessage };
  if (m.documentMessage) return { kind: 'document', node: m.documentMessage };
  return null;
}

function extForMime(mime, kind) {
  const map = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp',
    'audio/ogg': 'ogg',
    'audio/ogg; codecs=opus': 'ogg',
    'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a',
    'application/pdf': 'pdf',
  };
  const key = (mime || '').toLowerCase();
  if (map[key]) return map[key];
  if (key.startsWith('audio/ogg')) return 'ogg';
  const tail = key.split('/')[1];
  if (tail) return tail.replace(/[^a-z0-9]+/g, '').slice(0, 8) || 'bin';
  return 'bin';
}

function mediaMeta(msgId, node, mime, kind) {
  const size = Number(node.fileLength || 0);
  const id = String(msgId || '').replace(/[^A-Za-z0-9_-]/g, '');
  const path = join(MEDIA_DIR, `${id}.${extForMime(mime, kind)}`);
  return { path, mime, size };
}

async function downloadMedia(kind, node, dest, sizeHint) {
  if (sizeHint && sizeHint > MEDIA_MAX_BYTES) return;
  try {
    const dl = (async () => {
      const stream = await downloadContentFromMessage(node, kind);
      const chunks = [];
      let total = 0;
      for await (const c of stream) {
        total += c.length;
        if (total > MEDIA_MAX_BYTES) throw new Error('media exceeds cap');
        chunks.push(c);
      }
      writeFileSync(dest, Buffer.concat(chunks));
    })();
    const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error('media download timeout')), MEDIA_DL_TIMEOUT_MS));
    await Promise.race([dl, timeout]);
  } catch (err) {
    log.debug({ err: err?.message, dest }, 'media download failed (best-effort)');
  }
}

function pruneMedia() {
  try {
    const now = Date.now();
    for (const f of readdirSync(MEDIA_DIR)) {
      const p = join(MEDIA_DIR, f);
      try {
        if (now - statSync(p).mtimeMs > MEDIA_PRUNE_DAYS * 86400e3) unlinkSync(p);
      } catch {}
    }
  } catch {}
}

let current = null;
let connecting = false;

function cleanup(sock) {
  try { sock?.ev?.removeAllListeners?.(); } catch {}
  try { sock?.end?.(undefined); } catch {}
}

function backoff() {
  const base = Math.min(MAX_BACKOFF_MS, 2000 * 2 ** Math.min(status.attempt, 6));
  return base + Math.floor(base * 0.3 * Math.random());
}

function scheduleReconnect(code) {
  status.state = 'reconnecting';
  status.attempt += 1;
  status.reconnects += 1;
  persist();
  if (status.attempt >= RECONNECT_ALERT_AFTER && !status.alerted) {
    status.alerted = true;
    persist();
    notify(`🟠 WhatsApp ingest caiu e não reconecta (tentativa ${status.attempt}${code != null ? `, code ${code}` : ''}). Continuo tentando — o geo está sem contexto novo do WhatsApp.`);
  }
  const delay = backoff();
  log.warn({ code, attempt: status.attempt, delay }, 'scheduling reconnect');
  setTimeout(connect, delay);
}

async function connect() {
  if (connecting) return;
  connecting = true;
  let sock;
  try {
    const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
    const { version } = await fetchLatestBaileysVersion();
    log.info({ version }, 'baileys version');

    sock = makeWASocket({
      version,
      auth: state,
      printQRInTerminal: false,
      logger: pino({ level: 'warn' }),
      markOnlineOnConnect: false,
      syncFullHistory: false,
    });
    current = sock;
    sock.ev.on('creds.update', saveCreds);

    sock.ev.on('connection.update', async (update) => {
      const { connection, lastDisconnect, qr } = update;

      if (qr) {
        log.warn('QR code required — scan with WhatsApp app');
        qrcode.generate(qr, { small: true });
        try { writeFileSync(QR_PATH, qr); } catch {}
        status.state = 'awaiting_qr';
        persist();
      }

      if (connection === 'open') {
        const wasAlerted = status.alerted;
        connecting = false;
        status.state = 'connected';
        status.last_connect = new Date().toISOString();
        status.attempt = 0;
        status.alerted = false;
        persist();
        log.info({ me: sock.user?.id }, 'connected');
        if (wasAlerted) notify('🟢 WhatsApp ingest reconectado — coleta de contexto normalizada.');
      }

      if (connection === 'close') {
        const code = lastDisconnect?.error?.output?.statusCode;
        connecting = false;
        cleanup(sock);
        if (current === sock) current = null;

        if (code === DisconnectReason.loggedOut) {
          status.state = 'logged_out';
          persist();
          log.error({ code }, 'logged out — device removed, re-pair required');
          await notify('🔴 WhatsApp ingest DESLOGADO (device_removed). O geo PAROU de coletar contexto do WhatsApp. Me peça pra reconectar o zap (precisa escanear QR).');
          process.exit(0);
        }
        scheduleReconnect(code);
      }
    });

    sock.ev.on('messages.upsert', ({ messages, type }) => {
      if (type !== 'notify' && type !== 'append') return;
      for (const msg of messages) {
        try {
          const type = classify(msg);
          const record = {
            ts: new Date().toISOString(),
            msg_id: msg.key?.id,
            chat: msg.key?.remoteJid,
            sender: msg.key?.participant || msg.key?.remoteJid,
            from_me: !!msg.key?.fromMe,
            push_name: msg.pushName || null,
            is_group: (msg.key?.remoteJid || '').endsWith('@g.us'),
            type,
            text: extractText(msg),
          };
          let mnode = null;
          if (MEDIA_KINDS.has(type)) {
            try {
              mnode = mediaNodeFor(msg);
              if (mnode) {
                const mime = mnode.node.mimetype || '';
                record.media = mediaMeta(record.msg_id, mnode.node, mime, mnode.kind);
                const fn = mnode.node.fileName || mnode.node.title;
                if (fn) record.media.filename = fn;
              }
            } catch (err) {
              mnode = null;
              log.debug({ err: err?.message }, 'media meta failed (text unaffected)');
            }
          }
          appendFileSync(JSONL_PATH, JSON.stringify(record) + '\n');
          status.msg_count += 1;
          status.last_msg = record.ts;
          if (record.media && mnode) {
            setImmediate(() => downloadMedia(mnode.kind, mnode.node, record.media.path, record.media.size));
          }
        } catch (err) {
          log.error({ err: err.message }, 'failed to record message');
        }
      }
    });
  } catch (err) {
    connecting = false;
    cleanup(sock);
    log.error({ err: err.message }, 'connect failed');
    scheduleReconnect(null);
  }
}

if (!acquireLock()) {
  log.error('another whatsapp-ingest instance is running — exiting');
  process.exit(0);
}

pruneMedia();

setInterval(persist, 30000);
persist();

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => { status.state = 'stopped'; persist(); process.exit(0); });
}

process.on('unhandledRejection', (err) => {
  log.error({ err: err?.message }, 'unhandledRejection — scheduling reconnect');
  connecting = false;
  scheduleReconnect(null);
});

connect();
