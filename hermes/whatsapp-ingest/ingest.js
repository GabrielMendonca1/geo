import { makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion, DisconnectReason } from '@whiskeysockets/baileys';
import qrcode from 'qrcode-terminal';
import pino from 'pino';
import { appendFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';

const HERMES_HOME = join(homedir(), '.hermes');
const AUTH_DIR = join(HERMES_HOME, 'whatsapp-ingest', 'auth');
const JSONL_PATH = join(HERMES_HOME, 'wa_ingest.jsonl');

mkdirSync(dirname(JSONL_PATH), { recursive: true });
mkdirSync(AUTH_DIR, { recursive: true });

const log = pino({ level: process.env.HERMES_INGEST_LOG_LEVEL || 'info' });

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

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();
  log.info({ version }, 'baileys version');

  const sock = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: false,
    logger: pino({ level: 'warn' }),
    markOnlineOnConnect: false,
    syncFullHistory: false,
  });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', (update) => {
    const { connection, lastDisconnect, qr } = update;
    if (qr) {
      log.warn('QR code required — scan with WhatsApp app');
      qrcode.generate(qr, { small: true });
    }
    if (connection === 'open') {
      log.info({ me: sock.user?.id }, 'connected');
    }
    if (connection === 'close') {
      const code = lastDisconnect?.error?.output?.statusCode;
      const shouldReconnect = code !== DisconnectReason.loggedOut;
      log.warn({ code, shouldReconnect }, 'disconnected');
      if (shouldReconnect) {
        setTimeout(start, 3000);
      }
    }
  });

  sock.ev.on('messages.upsert', ({ messages, type }) => {
    if (type !== 'notify' && type !== 'append') return;
    for (const msg of messages) {
      try {
        const record = {
          ts: new Date().toISOString(),
          msg_id: msg.key?.id,
          chat: msg.key?.remoteJid,
          sender: msg.key?.participant || msg.key?.remoteJid,
          from_me: !!msg.key?.fromMe,
          push_name: msg.pushName || null,
          is_group: (msg.key?.remoteJid || '').endsWith('@g.us'),
          type: classify(msg),
          text: extractText(msg),
        };
        appendFileSync(JSONL_PATH, JSON.stringify(record) + '\n');
      } catch (err) {
        log.error({ err: err.message }, 'failed to record message');
      }
    }
  });
}

start().catch((err) => {
  log.error({ err: err.message, stack: err.stack }, 'fatal');
  process.exit(1);
});
