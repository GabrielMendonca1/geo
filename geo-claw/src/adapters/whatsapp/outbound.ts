import type { WAMessage } from '@whiskeysockets/baileys';

export type GuardResult = { allowed: boolean; reason?: string };

const PERSONAL_SUFFIX = '@s.whatsapp.net';

export function guardOutbound(targetJid: string, selfJid: string | null): GuardResult {
  if (selfJid === null) {
    return { allowed: false, reason: 'selfJid not yet known' };
  }
  if (!selfJid.endsWith(PERSONAL_SUFFIX)) {
    return { allowed: false, reason: 'selfJid is not a personal s.whatsapp.net jid' };
  }
  if (!targetJid.endsWith(PERSONAL_SUFFIX)) {
    return { allowed: false, reason: 'target is not a personal s.whatsapp.net jid' };
  }
  const normalizedTarget = normalizeJid(targetJid);
  const normalizedSelf = normalizeJid(selfJid);
  if (normalizedTarget !== normalizedSelf) {
    return { allowed: false, reason: 'target is not self-DM' };
  }
  return { allowed: true };
}

export function normalizeJid(jid: string): string {
  if (!jid) return jid;
  const atIdx = jid.indexOf('@');
  if (atIdx === -1) return jid;
  const user = jid.slice(0, atIdx);
  const server = jid.slice(atIdx + 1);
  const colonIdx = user.indexOf(':');
  const bareUser = colonIdx === -1 ? user : user.slice(0, colonIdx);
  return `${bareUser}@${server}`;
}

export function extractTextFromMessage(msg: WAMessage): string | null {
  const m = msg.message;
  if (!m) return null;
  if (typeof m.conversation === 'string' && m.conversation.length > 0) {
    return m.conversation;
  }
  const ext = m.extendedTextMessage?.text;
  if (typeof ext === 'string' && ext.length > 0) {
    return ext;
  }
  const imgCap = m.imageMessage?.caption;
  if (typeof imgCap === 'string' && imgCap.length > 0) {
    return imgCap;
  }
  const vidCap = m.videoMessage?.caption;
  if (typeof vidCap === 'string' && vidCap.length > 0) {
    return vidCap;
  }
  return null;
}
