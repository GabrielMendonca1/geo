import fs from 'node:fs/promises';
import { Boom } from '@hapi/boom';
import makeWASocket, {
  Browsers,
  DisconnectReason,
  fetchLatestBaileysVersion,
  useMultiFileAuthState,
  type ConnectionState,
  type WASocket,
} from '@whiskeysockets/baileys';
import { paths } from '../../config.js';
import { log } from '../../log.js';
import type { LLMLoop, StatusWriter } from '../../types.js';
import { handleInbound } from './inbound.js';
import { normalizeJid } from './outbound.js';
import { clearQrFile, writeQrFile } from './qr.js';

export interface WhatsappAdapter {
  start(): Promise<void>;
  stop(): Promise<void>;
  reset(): Promise<void>;
  sendToSelf(text: string): Promise<{ jid: string }>;
}

import type { McpClient } from '../../mcp/client.js';
import type { TelegramAdapter } from '../telegram/index.js';

export interface WhatsappAdapterDeps {
  llm: LLMLoop;
  status: StatusWriter;
  mcp: McpClient;
  telegram: TelegramAdapter | null;
}

const RECONNECT_DELAY_MS = 3000;

const silentLogger = {
  level: 'silent',
  child() {
    return silentLogger;
  },
  trace() {},
  debug() {},
  info() {},
  warn() {},
  error() {},
};

const SEEN_IDS_MAX = 1000;

export function createWhatsappAdapter(deps: WhatsappAdapterDeps): WhatsappAdapter {
  const { llm, status, mcp, telegram } = deps;

  let sock: WASocket | null = null;
  let selfJid: string | null = null;
  let isStopping = false;
  let reconnectTimer: NodeJS.Timeout | null = null;
  let starting = false;
  const seenIds: string[] = [];
  const seenIdSet = new Set<string>();

  function rememberId(id: string): boolean {
    if (seenIdSet.has(id)) return false;
    seenIdSet.add(id);
    seenIds.push(id);
    if (seenIds.length > SEEN_IDS_MAX) {
      const drop = seenIds.shift();
      if (drop !== undefined) seenIdSet.delete(drop);
    }
    return true;
  }

  function clearReconnectTimer(): void {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  }

  async function ensureAuthDir(): Promise<void> {
    await fs.mkdir(paths.authWhatsapp, { recursive: true });
  }

  async function startInternal(): Promise<void> {
    if (isStopping) return;
    if (sock) return;
    if (starting) return;
    starting = true;
    try {
      await ensureAuthDir();
      status.updateConnector('whatsapp', { state: 'connecting', detail: 'starting socket' });

      const { state, saveCreds } = await useMultiFileAuthState(paths.authWhatsapp);
      const { version, isLatest } = await fetchLatestBaileysVersion();
      log.info({ version, isLatest }, 'whatsapp:baileys-version');

      const newSock = makeWASocket({
        auth: state,
        version,
        printQRInTerminal: false,
        browser: Browsers.macOS('GeoClaw'),
        logger: silentLogger,
        markOnlineOnConnect: false,
      });
      sock = newSock;

      newSock.ev.on('creds.update', saveCreds);

      newSock.ev.on('connection.update', (update: Partial<ConnectionState>) => {
        const { connection, qr, lastDisconnect } = update;

        if (qr) {
          writeQrFile(qr).catch((err) => {
            log.error({ err: (err as Error).message }, 'whatsapp:qr-write-failed');
          });
          status.updateConnector('whatsapp', {
            state: 'qr',
            detail: 'scan QR with WhatsApp app',
          });
        }

        if (connection === 'open') {
          clearQrFile().catch(() => {});
          const userId = newSock.user?.id;
          if (!userId) {
            log.warn('whatsapp:open-without-user-id');
            selfJid = null;
          } else {
            selfJid = normalizeJid(userId);
          }
          status.updateConnector('whatsapp', {
            state: 'connected',
            identity: selfJid ?? undefined,
            detail: undefined,
            error: undefined,
          });
          log.info({ selfJid }, 'whatsapp:connected');
          return;
        }

        if (connection === 'close') {
          const err = lastDisconnect?.error as Boom | Error | undefined;
          const statusCode =
            err && (err as Boom).output?.statusCode
              ? (err as Boom).output.statusCode
              : undefined;
          const isLoggedOut = statusCode === DisconnectReason.loggedOut || statusCode === 401;
          log.warn(
            { statusCode, message: err?.message, isLoggedOut },
            'whatsapp:connection-closed',
          );

          if (sock === newSock) {
            sock = null;
          }
          selfJid = null;

          if (isStopping) {
            status.updateConnector('whatsapp', { state: 'disconnected', detail: 'stopped' });
            return;
          }

          if (isLoggedOut) {
            status.updateConnector('whatsapp', {
              state: 'disconnected',
              detail: 'logged out — call reset to re-pair',
              identity: undefined,
            });
            return;
          }

          status.updateConnector('whatsapp', {
            state: 'connecting',
            detail: 'reconnecting',
          });
          clearReconnectTimer();
          reconnectTimer = setTimeout(() => {
            reconnectTimer = null;
            startInternal().catch((reconnErr) => {
              log.error(
                { err: (reconnErr as Error).message },
                'whatsapp:reconnect-failed',
              );
              status.updateConnector('whatsapp', {
                state: 'error',
                error: (reconnErr as Error).message,
              });
            });
          }, RECONNECT_DELAY_MS);
        }
      });

      newSock.ev.on('messages.upsert', (payload) => {
        try {
          if (payload.type !== 'notify') return;
          const sendReply = async (jid: string, text: string): Promise<void> => {
            const current = sock;
            if (!current) throw new Error('socket not connected');
            await current.sendMessage(jid, { text });
          };
          for (const msg of payload.messages) {
            const id = msg.key?.id;
            if (id && !rememberId(id)) continue;
            handleInbound({ msg, selfJid, llm, sendReply, status, mcp, telegram }).catch((err) => {
              log.error({ err: (err as Error).message }, 'whatsapp:handle-inbound-error');
            });
          }
        } catch (err) {
          log.error({ err: (err as Error).message }, 'whatsapp:upsert-handler-error');
        }
      });
    } finally {
      starting = false;
    }
  }

  async function start(): Promise<void> {
    if (sock || starting) return;
    isStopping = false;
    await startInternal();
  }

  async function stop(): Promise<void> {
    isStopping = true;
    clearReconnectTimer();
    const current = sock;
    sock = null;
    selfJid = null;
    if (current) {
      try {
        current.end(undefined);
      } catch (err) {
        log.warn({ err: (err as Error).message }, 'whatsapp:stop-end-error');
      }
    }
    status.updateConnector('whatsapp', { state: 'disconnected', detail: 'stopped' });
  }

  async function reset(): Promise<void> {
    await stop();
    await clearQrFile();
    await fs.rm(paths.authWhatsapp, { recursive: true, force: true });
    await ensureAuthDir();
    isStopping = false;
    await start();
  }

  async function sendToSelf(text: string): Promise<{ jid: string; messageId: string | null }> {
    const current = sock;
    if (!current) throw new Error('whatsapp socket not connected');
    if (!selfJid) throw new Error('selfJid not yet known');
    const sent = await current.sendMessage(selfJid, { text });
    const messageId = sent?.key?.id ?? null;
    log.info({ jid: selfJid, messageId, textLen: text.length }, 'whatsapp:sent-to-self');
    return { jid: selfJid, messageId };
  }

  return { start, stop, reset, sendToSelf };
}
