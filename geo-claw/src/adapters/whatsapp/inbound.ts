import type { WAMessage } from '@whiskeysockets/baileys';
import { log } from '../../log.js';
import type { ChannelContext, LLMLoop, StatusWriter } from '../../types.js';
import type { McpClient } from '../../mcp/client.js';
import type { TelegramAdapter } from '../telegram/index.js';
import { extractTextFromMessage, guardOutbound, normalizeJid } from './outbound.js';
import { observe } from './observer.js';

export interface HandleInboundOpts {
  msg: WAMessage;
  selfJid: string | null;
  llm: LLMLoop;
  sendReply: (jid: string, text: string) => Promise<void>;
  status: StatusWriter;
  mcp: McpClient;
  telegram: TelegramAdapter | null;
}

export async function handleInbound(opts: HandleInboundOpts): Promise<void> {
  const { msg, selfJid, llm, sendReply, status, mcp, telegram } = opts;
  const key = msg.key;
  if (!key) return;
  if (key.fromMe) return;

  const rawJid = key.remoteJid;
  if (!rawJid) return;
  if (rawJid.endsWith('@g.us')) return;
  if (rawJid.endsWith('@broadcast')) return;
  if (rawJid.endsWith('@newsletter')) return;
  if (rawJid.endsWith('@lid')) return;
  if (rawJid === 'status@broadcast') return;
  if (!rawJid.endsWith('@s.whatsapp.net')) return;

  const remoteJid = normalizeJid(rawJid);
  const text = extractTextFromMessage(msg);
  if (text === null) return;

  const fromName = typeof msg.pushName === 'string' && msg.pushName.length > 0 ? msg.pushName : undefined;
  status.updateConnector('whatsapp', { lastEventAt: new Date().toISOString() });

  const isSelfDm = selfJid !== null && normalizeJid(selfJid) === remoteJid;

  if (!isSelfDm) {
    log.info({ jid: remoteJid, len: text.length }, 'inbound:observe');
    try {
      await observe({ fromName, fromAddress: remoteJid, body: text }, { mcp, telegram });
    } catch (err) {
      log.error({ err: (err as Error).message, jid: remoteJid }, 'inbound:observe-error');
    }
    return;
  }

  log.info({ jid: remoteJid, len: text.length }, 'inbound:self-dm');
  const ctx: ChannelContext = {
    channelId: remoteJid,
    channelKind: 'whatsapp',
    fromAddress: remoteJid,
    fromName,
  };

  let turn;
  try {
    turn = await llm.runTurn(ctx, text);
  } catch (err) {
    log.error({ err: (err as Error).message, jid: remoteJid }, 'inbound:llm-error');
    return;
  }

  const reply = turn?.reply ?? null;
  if (reply === null || reply.length === 0) return;

  const guard = guardOutbound(remoteJid, selfJid);
  if (!guard.allowed) {
    log.info({ jid: remoteJid, selfJid, reason: guard.reason }, 'outbound blocked');
    return;
  }

  try {
    await sendReply(remoteJid, reply);
    log.info({ jid: remoteJid, len: reply.length }, 'outbound:sent');
  } catch (err) {
    log.error({ err: (err as Error).message, jid: remoteJid }, 'outbound:send-error');
  }
}
