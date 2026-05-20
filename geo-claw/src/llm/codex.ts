import { spawn } from 'node:child_process';
import { log } from '../log.js';
import type { RunTurnResult } from './claude.js';

const TIMEOUT_MS = 90_000;

type CodexEvent = {
  type?: string;
  item?: {
    type?: string;
    text?: string;
    content?: Array<{ type?: string; text?: string }> | string;
  };
};

function extractAssistantText(line: string): string | null {
  let event: CodexEvent;
  try {
    event = JSON.parse(line) as CodexEvent;
  } catch {
    return null;
  }
  if (event.type !== 'item.completed') return null;
  const item = event.item;
  if (!item || item.type !== 'assistant_message') return null;
  if (typeof item.text === 'string' && item.text.length > 0) return item.text;
  if (Array.isArray(item.content)) {
    const parts: string[] = [];
    for (const c of item.content) {
      if (c && typeof c.text === 'string') parts.push(c.text);
    }
    if (parts.length > 0) return parts.join('\n');
  }
  if (typeof item.content === 'string') return item.content;
  return null;
}

export async function codexRunTurnImpl(opts: {
  system: string;
  userMessage: string;
}): Promise<RunTurnResult> {
  const args = [
    'exec',
    '--json',
    '--ephemeral',
    '--skip-git-repo-check',
    '--full-auto',
    '-m', process.env.GEO_CLAW_CODEX_MODEL ?? 'gpt-5.5',
    '-c', 'model_reasoning_effort=low',
    '-c', 'model_reasoning_summary=none',
    '-c', 'hide_agent_reasoning=true',
    '-c', `developer_instructions=${opts.system}`,
    opts.userMessage,
  ];

  const child = spawn('codex', args);

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk: Buffer) => {
    stdout += chunk.toString('utf8');
  });
  child.stderr.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8');
  });

  const exitCode: number = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch {}
      reject(new Error('codex CLI timeout'));
    }, TIMEOUT_MS);
    timer.unref?.();
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve(code ?? 0);
    });
  });

  if (stderr.length > 0) {
    log.debug({ stderr: stderr.slice(-2000) }, 'codex:stderr');
  }

  if (exitCode !== 0) {
    throw new Error(`codex CLI exited ${exitCode}: ${stderr.slice(-500)}`);
  }

  let text = '';
  for (const line of stdout.split('\n')) {
    const trimmed = line.trim();
    if (trimmed.length === 0) continue;
    const candidate = extractAssistantText(trimmed);
    if (candidate !== null) text = candidate;
  }

  return { text: text.trim() };
}

let codexLock: Promise<void> = Promise.resolve();

export async function codexRunTurn(opts: {
  system: string;
  userMessage: string;
}): Promise<RunTurnResult> {
  const prev = codexLock;
  let release: () => void = () => {};
  codexLock = new Promise<void>((resolve) => {
    release = resolve;
  });
  try {
    await prev;
    return await codexRunTurnImpl(opts);
  } finally {
    release();
  }
}
