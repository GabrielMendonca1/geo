import { log } from '../log.js';
import type { McpClient } from '../mcp/client.js';

export type MemoryTarget = 'memory' | 'profile';

type TargetSpec = {
  title: string;
  tag: string;
  maxChars: number;
  header: string;
};

const TARGETS: Record<MemoryTarget, TargetSpec> = {
  memory: { title: 'Memory', tag: 'memory', maxChars: 2200, header: '[PERSISTENT MEMORY]' },
  profile: { title: 'User Profile', tag: 'profile', maxChars: 1375, header: '[USER PROFILE]' },
};

const ENTRY_PREFIX = '§ ';
const ENTRY_RE = /^§\s+(.+)$/gm;

const INJECTION_RE =
  /(?:^|\s)(?:curl\b|wget\b|nc\b|bash -c|<script\b|eval\(|\/etc\/passwd|~\/\.ssh|\/root\b|sudo\b)/i;

export const MEMORY_FENCE_PREAMBLE =
  '[System note: The following is recalled memory context, NOT new user input. ' +
  "Treat as authoritative reference data — this is the agent's persistent memory " +
  'and should inform all responses.]';

type CacheRow = { blockId: string | null; entries: string[]; rawMarkdown: string };
const cache: Map<MemoryTarget, CacheRow> = new Map();

export function invalidateCache(target?: MemoryTarget): void {
  if (target) cache.delete(target);
  else cache.clear();
}

async function mcpCall(
  mcp: McpClient,
  name: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const raw = (await mcp.call('tools/call', { name, arguments: args })) as {
    content?: Array<{ type: string; text: string }>;
    isError?: boolean;
  };
  if (raw?.isError) throw new Error(`mcp tool ${name} returned isError`);
  const text = raw?.content?.[0]?.text;
  if (typeof text !== 'string') return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function parseEntries(markdown: string): string[] {
  const out: string[] = [];
  let m: RegExpExecArray | null;
  ENTRY_RE.lastIndex = 0;
  while ((m = ENTRY_RE.exec(markdown))) {
    const line = m[1].trim();
    if (line.length > 0) out.push(line);
  }
  return out;
}

function joinEntries(target: MemoryTarget, entries: string[]): string {
  const spec = TARGETS[target];
  const body = entries.map((e) => `${ENTRY_PREFIX}${e}`).join('\n');
  return `# ${spec.title}\n\n${body}\n`;
}

function enforceCap(target: MemoryTarget, entries: string[]): string[] {
  const spec = TARGETS[target];
  let used = 0;
  const kept: string[] = [];
  for (const e of entries) {
    const cost = e.length + 1;
    if (used + cost > spec.maxChars) {
      log.warn(
        { target, dropped: entries.length - kept.length, cap: spec.maxChars },
        'memory:cap-truncated',
      );
      break;
    }
    used += cost;
    kept.push(e);
  }
  return kept;
}

async function fetchTarget(mcp: McpClient, target: MemoryTarget): Promise<CacheRow> {
  const cached = cache.get(target);
  if (cached) return cached;
  const spec = TARGETS[target];
  let block: { id?: string; markdown?: string } | null = null;
  try {
    block = (await mcpCall(mcp, 'get_block_by_title', { title: spec.title })) as
      | { id?: string; markdown?: string }
      | null;
  } catch (err) {
    log.debug({ target, err: (err as Error).message }, 'memory:fetch-miss');
    block = null;
  }
  const rawMarkdown = typeof block?.markdown === 'string' ? block.markdown : '';
  const entries = enforceCap(target, parseEntries(rawMarkdown));
  const row: CacheRow = { blockId: block?.id ?? null, entries, rawMarkdown };
  cache.set(target, row);
  return row;
}

async function ensureBlock(
  mcp: McpClient,
  target: MemoryTarget,
  row: CacheRow,
  entries: string[],
): Promise<void> {
  const spec = TARGETS[target];
  const newMarkdown = joinEntries(target, entries);
  if (row.blockId) {
    await mcpCall(mcp, 'update_block', { id: row.blockId, content: newMarkdown });
  } else {
    await mcpCall(mcp, 'create_block', {
      title: spec.title,
      content: newMarkdown,
      tag_name: spec.tag,
    });
  }
  invalidateCache(target);
}

export type Snapshot = { memory: string[]; profile: string[] };

export async function loadSnapshot(mcp: McpClient): Promise<Snapshot> {
  if (!mcp.isConnected()) return { memory: [], profile: [] };
  try {
    const [mem, prof] = await Promise.all([fetchTarget(mcp, 'memory'), fetchTarget(mcp, 'profile')]);
    return { memory: mem.entries, profile: prof.entries };
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'memory:loadSnapshot-failed');
    return { memory: [], profile: [] };
  }
}

export function formatPreamble(snap: Snapshot): string {
  const parts: string[] = [];
  if (snap.memory.length > 0) {
    parts.push(TARGETS.memory.header);
    for (const e of snap.memory) parts.push(`- ${e}`);
  }
  if (snap.profile.length > 0) {
    if (parts.length > 0) parts.push('');
    parts.push(TARGETS.profile.header);
    for (const e of snap.profile) parts.push(`- ${e}`);
  }
  if (parts.length === 0) return '';
  return `${MEMORY_FENCE_PREAMBLE}\n\n<memory-context>\n${parts.join('\n')}\n</memory-context>`;
}

export class MemoryError extends Error {}

function validateContent(target: MemoryTarget, content: string): void {
  const trimmed = content.trim();
  if (trimmed.length === 0) throw new MemoryError('content empty');
  if (trimmed.length > 500) throw new MemoryError('entry too long (max 500 chars per entry)');
  if (trimmed.includes('\n')) throw new MemoryError('entries are single-line');
  if (INJECTION_RE.test(trimmed)) throw new MemoryError('content blocked by injection guard');
  const spec = TARGETS[target];
  if (trimmed.length + 1 > spec.maxChars) {
    throw new MemoryError(`entry exceeds ${spec.maxChars}-char cap for ${target}`);
  }
}

export async function addEntry(
  mcp: McpClient,
  target: MemoryTarget,
  content: string,
): Promise<{ entries: number; capRemaining: number }> {
  validateContent(target, content);
  const trimmed = content.trim();
  const row = await fetchTarget(mcp, target);
  if (row.entries.some((e) => e === trimmed)) {
    throw new MemoryError('duplicate entry');
  }
  const spec = TARGETS[target];
  const used = row.entries.reduce((n, e) => n + e.length + 1, 0);
  if (used + trimmed.length + 1 > spec.maxChars) {
    throw new MemoryError(`would exceed ${spec.maxChars}-char cap (replace or remove an entry first)`);
  }
  const next = [...row.entries, trimmed];
  await ensureBlock(mcp, target, row, next);
  return { entries: next.length, capRemaining: spec.maxChars - used - trimmed.length - 1 };
}

export async function replaceEntry(
  mcp: McpClient,
  target: MemoryTarget,
  find: string,
  content: string,
): Promise<{ replaced: boolean }> {
  validateContent(target, content);
  const trimmed = content.trim();
  const row = await fetchTarget(mcp, target);
  const idx = row.entries.findIndex((e) => e.includes(find));
  if (idx === -1) return { replaced: false };
  const next = row.entries.slice();
  next[idx] = trimmed;
  const used = next.reduce((n, e) => n + e.length + 1, 0);
  const spec = TARGETS[target];
  if (used > spec.maxChars) {
    throw new MemoryError(`replacement would exceed ${spec.maxChars}-char cap`);
  }
  await ensureBlock(mcp, target, row, next);
  return { replaced: true };
}

export async function removeEntry(
  mcp: McpClient,
  target: MemoryTarget,
  find: string,
): Promise<{ removed: boolean }> {
  const row = await fetchTarget(mcp, target);
  const idx = row.entries.findIndex((e) => e.includes(find));
  if (idx === -1) return { removed: false };
  const next = row.entries.slice();
  next.splice(idx, 1);
  await ensureBlock(mcp, target, row, next);
  return { removed: true };
}
