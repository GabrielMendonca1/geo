import { claudeRunTurn } from '../../llm/claude.js';
import { log } from '../../log.js';
import type { McpClient } from '../../mcp/client.js';
import type { TelegramAdapter } from '../telegram/index.js';

const NOISE_RE = /^(ok|kk+|haha+|kkk+|sim|nao|n[aã]o|yes|no|y|n|alo|al[oô]|👍|❤️|🙏|😂|🤣|🥰|✨|👋|🔥)+\.?!?$/iu;
const MIN_CHARS = 6;
const HAIKU_MODEL = 'claude-haiku-4-5';

type Classification = {
  kind: 'NONE' | 'NOTE' | 'TASK';
  text?: string;
  dueIso?: string | null;
};

const CLASSIFIER_PROMPT = `You read a single incoming WhatsApp DM that Gabriel received.
Classify it and output ONE JSON object on a single line. No prose, no markdown.

Schema: {"kind": "NONE"|"NOTE"|"TASK", "text": string?, "dueIso": string?}

- NONE: greetings, small talk, emoji-only, generic chat, jokes.
- NOTE: factual content worth journaling — plans, events, decisions, references, names, places, agreements. text: a one-line bullet (no leading dash) in the message's original language summarizing the fact.
- TASK: explicit request that Gabriel do something concrete. text: imperative task title in original language. dueIso: ISO-8601 timestamp if a date/time is implied (interpret "tomorrow", "Friday", "until 5pm" relative to NOW provided in user content), else null.

Default to NONE when uncertain. Be conservative — most WhatsApp DMs are NONE.`;

export interface ObserveDeps {
  mcp: McpClient;
  telegram: TelegramAdapter | null;
}

export interface ObserveInput {
  fromName?: string;
  fromAddress: string;
  body: string;
}

const dayLocks: Map<string, Promise<void>> = new Map();

function todayISO(): string {
  return new Date().toISOString().slice(0, 10);
}

function nowISO(): string {
  return new Date().toISOString();
}

function isNoise(body: string): boolean {
  const trimmed = body.trim();
  if (trimmed.length < MIN_CHARS) return true;
  if (NOISE_RE.test(trimmed)) return true;
  if (trimmed.split(/\s+/).length < 3) return true;
  return false;
}

function tryParseJson(raw: string): Classification | null {
  const match = raw.match(/\{[\s\S]*?\}/);
  if (!match) return null;
  try {
    const parsed = JSON.parse(match[0]) as Classification;
    if (parsed.kind !== 'NONE' && parsed.kind !== 'NOTE' && parsed.kind !== 'TASK') return null;
    return parsed;
  } catch {
    return null;
  }
}

async function classify(input: ObserveInput): Promise<Classification | null> {
  const userMessage = `NOW: ${nowISO()}\nFROM: ${input.fromName ?? input.fromAddress}\nMESSAGE: ${input.body}`;
  try {
    const result = await claudeRunTurn({
      system: CLASSIFIER_PROMPT,
      userMessage,
      model: HAIKU_MODEL,
      maxTurns: 1,
      withGeoMcp: false,
    });
    return tryParseJson(result.text);
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'observer:classify-failed');
    return null;
  }
}

async function mcpCallTool(mcp: McpClient, name: string, args: Record<string, unknown>): Promise<unknown> {
  const raw = await mcp.call('tools/call', { name, arguments: args }) as { content?: Array<{ type: string; text: string }>; isError?: boolean };
  if (raw?.isError) {
    throw new Error(`mcp tool ${name} returned isError`);
  }
  const text = raw?.content?.[0]?.text;
  if (typeof text !== 'string') return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function appendBulletToDailyBlock(mcp: McpClient, day: string, bullet: string): Promise<void> {
  const blockId = `WhatsApp-${day}.md`;
  let existingMarkdown: string | null = null;
  try {
    const block = await mcpCallTool(mcp, 'get_block', { id: blockId }) as { markdown?: string } | null;
    if (block && typeof block.markdown === 'string') {
      existingMarkdown = block.markdown;
    }
  } catch {
    existingMarkdown = null;
  }
  if (existingMarkdown !== null) {
    const newContent = existingMarkdown.replace(/\s+$/, '') + '\n' + bullet + '\n';
    await mcpCallTool(mcp, 'update_block', { id: blockId, content: newContent });
  } else {
    const content = `# WhatsApp ${day}\n\n${bullet}\n`;
    await mcpCallTool(mcp, 'create_block', {
      title: `WhatsApp ${day}`,
      content,
      tag_name: 'whatsapp-observe',
      day_id: day,
    });
  }
}

async function withDayLock(day: string, op: () => Promise<void>): Promise<void> {
  const prev = dayLocks.get(day) ?? Promise.resolve();
  const next = prev.then(op, op).catch((err) => {
    log.error({ err: (err as Error).message, day }, 'observer:lock-task-failed');
  });
  dayLocks.set(day, next);
  await next;
}

async function handleNote(deps: ObserveDeps, input: ObserveInput, action: Classification): Promise<void> {
  if (!deps.mcp.isConnected()) {
    log.debug('observer:note skipped — mcp not connected');
    return;
  }
  const day = todayISO();
  const speaker = input.fromName ?? input.fromAddress;
  const bullet = `- (${speaker}) ${action.text ?? input.body}`;
  await withDayLock(day, async () => {
    await appendBulletToDailyBlock(deps.mcp, day, bullet);
    log.info({ day, speaker }, 'observer:note-written');
  });
}

async function handleTask(deps: ObserveDeps, input: ObserveInput, action: Classification): Promise<void> {
  if (!deps.mcp.isConnected()) {
    log.debug('observer:task skipped — mcp not connected');
    return;
  }
  const speaker = input.fromName ?? input.fromAddress;
  const title = action.text ?? input.body.slice(0, 80);
  const startTime = action.dueIso && /^\d{4}-\d{2}-\d{2}T/.test(action.dueIso)
    ? action.dueIso
    : new Date(Date.now() + 24 * 3600 * 1000).toISOString();
  try {
    await mcpCallTool(deps.mcp, 'create_task', {
      title,
      start_time: startTime,
      notes: `WhatsApp DM with ${speaker} — ${nowISO()}\n\n${input.body}`,
      kind: 'task',
      priority: 'unset',
    });
    log.info({ speaker, title }, 'observer:task-created');
  } catch (err) {
    log.warn({ err: (err as Error).message, speaker }, 'observer:create-task-failed');
    return;
  }
  if (deps.telegram) {
    try {
      await deps.telegram.sendToOwner(`📝 New task from WhatsApp\n${title}\n(from ${speaker})`);
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'observer:telegram-ping-failed');
    }
  }
}

export async function observe(input: ObserveInput, deps: ObserveDeps): Promise<void> {
  if (isNoise(input.body)) {
    log.debug({ from: input.fromAddress }, 'observer:skipped-noise');
    return;
  }
  const action = await classify(input);
  if (!action) return;
  if (action.kind === 'NONE') return;
  if (action.kind === 'NOTE') {
    await handleNote(deps, input, action);
  } else if (action.kind === 'TASK') {
    await handleTask(deps, input, action);
  }
}
