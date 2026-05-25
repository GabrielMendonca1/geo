import type { gmail_v1 } from 'googleapis';
import { log } from '../../log.js';
import { kvGet, kvSet } from '../../store/db.js';
import type { ChannelContext, LLMLoop, StatusWriter } from '../../types.js';
import { markRead, sendReply as sendReplyOutbound } from './outbound.js';

const HISTORY_KEY = 'gmail.historyId';
const MAX_BODY_BYTES = 50_000;
const SKIP_LABELS = new Set([
  'SENT',
  'DRAFT',
  'CHAT',
  'SPAM',
  'TRASH',
  'CATEGORY_PROMOTIONS',
  'CATEGORY_UPDATES',
  'CATEGORY_FORUMS',
]);

export type SendReplyFn = (args: {
  gmail: gmail_v1.Gmail;
  from: string;
  threadId: string;
  to: string;
  subject: string;
  inReplyTo: string;
  references: string;
  body: string;
}) => Promise<void>;

export type PollOptions = {
  gmail: gmail_v1.Gmail;
  userEmail: string;
  llm: LLMLoop;
  status: StatusWriter;
  sendReply?: SendReplyFn;
};

function getHeader(headers: gmail_v1.Schema$MessagePartHeader[] | undefined, name: string): string {
  if (!headers) return '';
  const lower = name.toLowerCase();
  for (const h of headers) {
    if ((h.name ?? '').toLowerCase() === lower) {
      return h.value ?? '';
    }
  }
  return '';
}

export function parseAddress(headerValue: string): { name?: string; email: string } {
  const value = (headerValue ?? '').trim();
  if (!value) return { email: '' };
  const angle = value.match(/^\s*"?([^"<]*?)"?\s*<([^>]+)>\s*$/);
  if (angle) {
    const name = angle[1].trim();
    const email = angle[2].trim();
    return name ? { name, email } : { email };
  }
  return { email: value };
}

function decodeBody(data: string): string {
  const normalized = data.replace(/-/g, '+').replace(/_/g, '/');
  try {
    return Buffer.from(normalized, 'base64').toString('utf8');
  } catch {
    return '';
  }
}

function stripHtml(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/p>/gi, '\n\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function ensureAngleBrackets(id: string): string {
  const trimmed = id.trim();
  if (!trimmed) return '';
  if (trimmed.startsWith('<') && trimmed.endsWith('>')) return trimmed;
  return `<${trimmed.replace(/^<|>$/g, '')}>`;
}

export function cleanReplyBody(body: string): string {
  if (!body) return '';
  const lines = body.split(/\r?\n/);
  let cutoff = lines.length;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (/^On .+ wrote:\s*$/.test(line) || /^-{2,}\s*Original Message\s*-{2,}/i.test(line)) {
      cutoff = i;
      break;
    }
  }
  let out = lines.slice(0, cutoff).join('\n');
  out = out.replace(/(^|\n)>[^\n]*(\n>[^\n]*)*$/g, '');
  out = out.trim();
  if (Buffer.byteLength(out, 'utf8') > MAX_BODY_BYTES) {
    out = Buffer.from(out, 'utf8').slice(0, MAX_BODY_BYTES).toString('utf8');
  }
  return out;
}

export function extractPlainText(payload: gmail_v1.Schema$MessagePart): string {
  const findPart = (
    part: gmail_v1.Schema$MessagePart | undefined,
    mime: string,
  ): gmail_v1.Schema$MessagePart | null => {
    if (!part) return null;
    if ((part.mimeType ?? '').toLowerCase() === mime && part.body?.data) {
      return part;
    }
    const parts = part.parts ?? [];
    for (const child of parts) {
      const found = findPart(child, mime);
      if (found) return found;
    }
    return null;
  };

  const plain = findPart(payload, 'text/plain');
  if (plain && plain.body?.data) {
    return decodeBody(plain.body.data).trim();
  }
  const html = findPart(payload, 'text/html');
  if (html && html.body?.data) {
    return stripHtml(decodeBody(html.body.data));
  }
  if (payload.body?.data) {
    const decoded = decodeBody(payload.body.data);
    if ((payload.mimeType ?? '').toLowerCase().includes('html')) {
      return stripHtml(decoded);
    }
    return decoded.trim();
  }
  return '';
}

async function processMessage(opts: {
  gmail: gmail_v1.Gmail;
  userEmail: string;
  llm: LLMLoop;
  messageId: string;
  sendReply: SendReplyFn;
}): Promise<void> {
  const { gmail, userEmail, llm, messageId, sendReply } = opts;
  const res = await gmail.users.messages.get({ userId: 'me', id: messageId, format: 'full' });
  const msg = res.data;
  const labels = msg.labelIds ?? [];
  for (const label of labels) {
    if (SKIP_LABELS.has(label)) return;
  }

  const headers = msg.payload?.headers ?? [];
  const fromHeader = getHeader(headers, 'From');
  const subject = getHeader(headers, 'Subject');
  const rawMessageId = getHeader(headers, 'Message-ID') || getHeader(headers, 'Message-Id');
  const messageIdHeader = ensureAngleBrackets(rawMessageId);
  const inReplyTo = getHeader(headers, 'In-Reply-To');
  const references = getHeader(headers, 'References');
  const from = parseAddress(fromHeader);

  if (!from.email) {
    log.warn({ messageId }, 'gmail: skipping message with no From email');
    return;
  }
  const normalizedFrom = from.email.toLowerCase().trim();
  const normalizedSelf = userEmail.toLowerCase().trim();
  if (normalizedFrom === normalizedSelf) {
    return;
  }

  const rawBody = msg.payload ? extractPlainText(msg.payload) : '';
  const body = cleanReplyBody(rawBody);
  const threadId = msg.threadId ?? '';
  if (!threadId) {
    log.warn({ messageId }, 'gmail: skipping message with no threadId');
    return;
  }

  const ctx: ChannelContext = {
    channelId: threadId,
    channelKind: 'gmail',
    fromName: from.name,
    fromAddress: from.email,
    metadata: {
      subject,
      messageId: messageIdHeader,
      references,
      inReplyTo,
    },
  };

  let turn;
  try {
    turn = await llm.runTurn(ctx, body);
  } catch (err) {
    log.error({ err: (err as Error).message, messageId }, 'gmail: llm error');
    try {
      await markRead(gmail, messageId);
    } catch (markErr) {
      log.warn({ err: (markErr as Error).message, messageId }, 'gmail: failed to mark read after llm error');
    }
    return;
  }

  if (!turn.reply) {
    try {
      await markRead(gmail, messageId);
    } catch (err) {
      log.warn({ err: (err as Error).message, messageId }, 'gmail: failed to mark read');
    }
    return;
  }

  const newReferences = [references, messageIdHeader].filter((s) => s && s.length > 0).join(' ');
  try {
    await sendReply({
      gmail,
      from: userEmail,
      threadId,
      to: from.email,
      subject,
      inReplyTo: messageIdHeader,
      references: newReferences,
      body: turn.reply,
    });
  } catch (err) {
    log.error({ err: (err as Error).message, messageId }, 'gmail: send reply failed');
  }

  try {
    await markRead(gmail, messageId);
  } catch (err) {
    log.warn({ err: (err as Error).message, messageId }, 'gmail: failed to mark read after reply');
  }
}

export async function pollOnce(opts: PollOptions): Promise<void> {
  const { gmail, userEmail, llm, status } = opts;
  const sendReply = opts.sendReply ?? sendReplyOutbound;

  const stored = kvGet(HISTORY_KEY);
  if (!stored) {
    const profile = await gmail.users.getProfile({ userId: 'me' });
    const id = profile.data.historyId;
    if (id) {
      kvSet(HISTORY_KEY, id);
      log.info({ historyId: id }, 'gmail: bootstrap historyId stored, skipping initial backlog');
    }
    status.updateConnector('gmail', { lastEventAt: new Date().toISOString() });
    return;
  }

  const seen = new Set<string>();
  let pageToken: string | undefined;
  let latestHistoryId = stored;

  do {
    const resp = await gmail.users.history.list({
      userId: 'me',
      startHistoryId: stored,
      historyTypes: ['messageAdded'],
      ...(pageToken ? { pageToken } : {}),
    });
    const data = resp.data;
    if (data.historyId) {
      latestHistoryId = data.historyId;
    }
    const records = data.history ?? [];
    for (const rec of records) {
      if (rec.id) {
        const recIdNum = Number(rec.id);
        const latestNum = Number(latestHistoryId);
        if (Number.isFinite(recIdNum) && Number.isFinite(latestNum) && recIdNum > latestNum) {
          latestHistoryId = rec.id;
        }
      }
      const added = rec.messagesAdded ?? [];
      for (const entry of added) {
        const id = entry.message?.id;
        if (!id || seen.has(id)) continue;
        seen.add(id);
        try {
          await processMessage({ gmail, userEmail, llm, messageId: id, sendReply });
        } catch (err) {
          log.error(
            { err: (err as Error).message, messageId: id },
            'gmail: error processing message',
          );
        }
      }
    }
    pageToken = data.nextPageToken ?? undefined;
  } while (pageToken);

  if (latestHistoryId && latestHistoryId !== stored) {
    kvSet(HISTORY_KEY, latestHistoryId);
  }

  status.updateConnector('gmail', { lastEventAt: new Date().toISOString() });
}
