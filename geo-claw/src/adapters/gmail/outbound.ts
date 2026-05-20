import type { gmail_v1 } from 'googleapis';

export function encodeBase64Url(s: string): string {
  return Buffer.from(s, 'utf8')
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function ensureRePrefix(subject: string): string {
  const trimmed = subject.trim();
  if (/^re:\s*/i.test(trimmed)) return trimmed;
  return `Re: ${trimmed}`;
}

function isAscii(value: string): boolean {
  for (let i = 0; i < value.length; i += 1) {
    if (value.charCodeAt(i) > 0x7e) return false;
  }
  return true;
}

export function encodeHeaderValue(value: string): string {
  if (isAscii(value)) return value;
  const b64 = Buffer.from(value, 'utf8').toString('base64');
  return `=?utf-8?B?${b64}?=`;
}

function foldHeader(name: string, value: string, encode = false): string {
  const single = value.replace(/\r?\n/g, ' ');
  const out = encode ? encodeHeaderValue(single) : single;
  return `${name}: ${out}`;
}

export function buildReplyMime(args: {
  from: string;
  to: string;
  subject: string;
  inReplyTo: string;
  references: string;
  body: string;
}): string {
  const subject = ensureRePrefix(args.subject || '');
  const headers: string[] = ['MIME-Version: 1.0'];
  headers.push(foldHeader('From', args.from, true));
  headers.push(foldHeader('To', args.to, true));
  headers.push(foldHeader('Subject', subject, true));
  if (args.inReplyTo && args.inReplyTo.trim().length > 0) {
    headers.push(foldHeader('In-Reply-To', args.inReplyTo));
  }
  if (args.references && args.references.trim().length > 0) {
    headers.push(foldHeader('References', args.references));
  }
  headers.push('Content-Type: text/plain; charset=utf-8');
  headers.push('Content-Transfer-Encoding: 8bit');
  const normalizedBody = args.body.replace(/\r?\n/g, '\r\n');
  return `${headers.join('\r\n')}\r\n\r\n${normalizedBody}`;
}

export async function sendReply(args: {
  gmail: gmail_v1.Gmail;
  from: string;
  threadId: string;
  to: string;
  subject: string;
  inReplyTo: string;
  references: string;
  body: string;
}): Promise<void> {
  const mime = buildReplyMime({
    from: args.from,
    to: args.to,
    subject: args.subject,
    inReplyTo: args.inReplyTo,
    references: args.references,
    body: args.body,
  });
  const raw = encodeBase64Url(mime);
  await args.gmail.users.messages.send({
    userId: 'me',
    requestBody: { raw, threadId: args.threadId },
  });
}

export async function markRead(gmail: gmail_v1.Gmail, messageId: string): Promise<void> {
  await gmail.users.messages.modify({
    userId: 'me',
    id: messageId,
    requestBody: { removeLabelIds: ['UNREAD'] },
  });
}
