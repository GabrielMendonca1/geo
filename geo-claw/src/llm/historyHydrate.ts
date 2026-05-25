import { loadHistory } from '../store/db.js';

const MAX_CHARS_PER_MESSAGE = 600;

function extractText(contentRaw: string): string {
  try {
    const parsed = JSON.parse(contentRaw);
    if (parsed && typeof parsed === 'object') {
      const o = parsed as { text?: unknown };
      if (typeof o.text === 'string') return o.text;
    }
  } catch {
  }
  return contentRaw;
}

function truncate(s: string): string {
  if (s.length <= MAX_CHARS_PER_MESSAGE) return s;
  return s.slice(0, MAX_CHARS_PER_MESSAGE - 1) + '…';
}

export function loadAndFormatHistory(channelId: string, n = 20): string {
  const rows = loadHistory(channelId, n);
  if (rows.length === 0) return '';
  const lines: string[] = ['<recent-history>'];
  for (const r of rows) {
    const text = truncate(extractText(r.content).replace(/\s+$/g, ''));
    if (text.length === 0) continue;
    lines.push(`${r.role}: ${text}`);
  }
  if (lines.length === 1) return '';
  lines.push('</recent-history>');
  return lines.join('\n');
}
