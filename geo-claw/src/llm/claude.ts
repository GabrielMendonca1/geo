import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { log } from '../log.js';
import { buildMcpConfigJson } from '../mcp/config.js';
import type { RunTurnEvent } from '../types.js';

export type RunTurnResult = { text: string; usage?: unknown };
export type RunTurnOptions = {
  system: string;
  userMessage: string;
  sessionKey?: string;
  onChunk?: (delta: string) => void;
  onEvent?: (event: RunTurnEvent) => void;
  model?: string;
  effort?: string;
  maxTurns?: number;
  withGeoMcp?: boolean;
  /** Use a long-lived `claude` process per sessionKey for low-latency multi-turn. */
  warm?: boolean;
};

const COLD_TIMEOUT_MS = 60_000;
const WARM_TURN_TIMEOUT_MS = 120_000;
const MAX_STDOUT_BYTES = 10 * 1024 * 1024;

const coldSessionByKey = new Map<string, string>();

function getColdSessionId(key: string): { id: string; isFirst: boolean } {
  const existing = coldSessionByKey.get(key);
  if (existing) return { id: existing, isFirst: false };
  const id = randomUUID();
  coldSessionByKey.set(key, id);
  return { id, isFirst: true };
}

type StreamCallbacks = {
  onChunk?: (delta: string) => void;
  onEvent?: (event: RunTurnEvent) => void;
  accumulated: { value: string };
  finalText: { value: string };
  emittedToolUse: Set<string>;
  emittedToolResult: Set<string>;
};

function processStreamLine(line: string, cb: StreamCallbacks): { isResult: boolean } {
  const trimmed = line.trim();
  if (!trimmed) return { isResult: false };
  let evt: unknown;
  try {
    evt = JSON.parse(trimmed);
  } catch {
    return { isResult: false };
  }
  const obj = evt as Record<string, unknown>;
  if (obj.type === 'stream_event') {
    const event = obj.event as Record<string, unknown> | undefined;
    if (event?.type === 'content_block_delta') {
      const delta = event.delta as Record<string, unknown> | undefined;
      if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
        cb.accumulated.value += delta.text;
        cb.onChunk?.(delta.text);
        cb.onEvent?.({ type: 'text', delta: delta.text });
      }
    }
    return { isResult: false };
  }
  if (obj.type === 'assistant' && cb.onEvent) {
    const message = obj.message as { content?: unknown } | undefined;
    const blocks = Array.isArray(message?.content) ? message!.content : [];
    for (const block of blocks) {
      const b = block as Record<string, unknown>;
      if (b.type === 'tool_use' && typeof b.id === 'string' && typeof b.name === 'string') {
        if (!cb.emittedToolUse.has(b.id)) {
          cb.emittedToolUse.add(b.id);
          cb.onEvent({ type: 'tool_use', toolUseId: b.id, name: b.name, input: b.input ?? {} });
        }
      }
    }
    return { isResult: false };
  }
  if (obj.type === 'user' && cb.onEvent) {
    const message = obj.message as { content?: unknown } | undefined;
    const blocks = Array.isArray(message?.content) ? message!.content : [];
    for (const block of blocks) {
      const b = block as Record<string, unknown>;
      if (b.type === 'tool_result' && typeof b.tool_use_id === 'string') {
        if (!cb.emittedToolResult.has(b.tool_use_id)) {
          cb.emittedToolResult.add(b.tool_use_id);
          cb.onEvent({
            type: 'tool_result',
            toolUseId: b.tool_use_id,
            content: b.content ?? null,
            isError: b.is_error === true,
          });
        }
      }
    }
    return { isResult: false };
  }
  if (obj.type === 'result') {
    if (typeof obj.result === 'string') cb.finalText.value = obj.result;
    return { isResult: true };
  }
  return { isResult: false };
}

// ---------- cold path (existing behavior) ----------

async function claudeRunTurnCold(opts: RunTurnOptions): Promise<RunTurnResult> {
  const mcpConfig = buildMcpConfigJson();

  const { id: sessionId, isFirst } = opts.sessionKey
    ? getColdSessionId(opts.sessionKey)
    : { id: randomUUID(), isFirst: true };

  const args = [
    '-p', opts.userMessage,
    '--output-format', 'stream-json',
    '--include-partial-messages',
    '--verbose',
    isFirst ? '--session-id' : '--resume',
    sessionId,
    '--max-turns', String(opts.maxTurns ?? 4),
    '--append-system-prompt', opts.system,
    '--model', opts.model ?? process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-opus-4-7',
    '--effort', opts.effort ?? process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'medium',
  ];
  if (opts.withGeoMcp !== false) {
    args.push('--strict-mcp-config', '--mcp-config', mcpConfig);
  }

  const child = spawn('claude', args, { env: process.env });

  let stdoutBuf = '';
  let stdoutBytes = 0;
  let stderr = '';
  let aborted = false;

  const cb: StreamCallbacks = {
    onChunk: opts.onChunk,
    onEvent: opts.onEvent,
    accumulated: { value: '' },
    finalText: { value: '' },
    emittedToolUse: new Set(),
    emittedToolResult: new Set(),
  };

  child.stdout.on('data', (chunk: Buffer) => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > MAX_STDOUT_BYTES) {
      if (!aborted) {
        aborted = true;
        try { child.kill('SIGKILL'); } catch {}
      }
      return;
    }
    stdoutBuf += chunk.toString('utf8');
    let nl: number;
    while ((nl = stdoutBuf.indexOf('\n')) !== -1) {
      const line = stdoutBuf.slice(0, nl);
      stdoutBuf = stdoutBuf.slice(nl + 1);
      processStreamLine(line, cb);
    }
  });
  child.stderr.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8');
  });

  const exitCode: number = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch {}
      reject(new Error('claude CLI timeout'));
    }, COLD_TIMEOUT_MS);
    timer.unref?.();
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (stdoutBuf.trim()) processStreamLine(stdoutBuf, cb);
      resolve(code ?? 0);
    });
  });

  if (stderr.length > 0) {
    log.debug({ stderr: stderr.slice(-2000) }, 'claude:stderr');
  }

  if (aborted) {
    throw new Error('claude CLI output exceeded cap (10MB)');
  }
  if (exitCode !== 0) {
    if (opts.sessionKey) coldSessionByKey.delete(opts.sessionKey);
    throw new Error(`claude CLI exited ${exitCode}: ${stderr.slice(-500)}`);
  }

  const text = (cb.finalText.value || cb.accumulated.value).trim();
  return { text };
}

// ---------- warm path (long-lived per-session CLI) ----------

type InflightTurn = {
  cb: StreamCallbacks;
  resolve: (result: RunTurnResult) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};

type WarmSession = {
  child: ChildProcessWithoutNullStreams;
  sessionId: string;
  systemPromptFingerprint: string;
  stdoutBuf: string;
  stderr: string;
  inflight?: InflightTurn;
  exited: boolean;
};

const warmSessions = new Map<string, WarmSession>();

function fingerprintSpawn(opts: RunTurnOptions): string {
  const model = opts.model ?? process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-opus-4-7';
  const effort = opts.effort ?? process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'medium';
  const maxTurns = String(opts.maxTurns ?? 4);
  // Fingerprint covers everything baked in at spawn time.
  return `${model}|${effort}|${maxTurns}|${opts.system.length}|${opts.system.slice(0, 64)}`;
}

function spawnWarmSession(opts: RunTurnOptions): WarmSession {
  const mcpConfig = buildMcpConfigJson();
  const sessionId = randomUUID();
  const args = [
    '-p',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--include-partial-messages',
    '--verbose',
    '--session-id', sessionId,
    '--append-system-prompt', opts.system,
    '--model', opts.model ?? process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-opus-4-7',
    '--effort', opts.effort ?? process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'medium',
    '--max-turns', String(opts.maxTurns ?? 4),
  ];
  if (opts.withGeoMcp !== false) {
    args.push('--strict-mcp-config', '--mcp-config', mcpConfig);
  }

  const child = spawn('claude', args, { env: process.env, stdio: ['pipe', 'pipe', 'pipe'] }) as ChildProcessWithoutNullStreams;
  const session: WarmSession = {
    child,
    sessionId,
    systemPromptFingerprint: fingerprintSpawn(opts),
    stdoutBuf: '',
    stderr: '',
    exited: false,
  };

  child.stdout.on('data', (chunk: Buffer) => onWarmStdout(session, chunk));
  child.stderr.on('data', (chunk: Buffer) => {
    session.stderr += chunk.toString('utf8');
    if (session.stderr.length > 64_000) {
      session.stderr = session.stderr.slice(-32_000);
    }
  });
  child.on('error', (err) => onWarmExit(session, null, err));
  child.on('close', (code) => onWarmExit(session, code, null));

  log.info({ sessionId, model: opts.model, effort: opts.effort }, 'warm claude session spawned');
  return session;
}

function onWarmStdout(session: WarmSession, chunk: Buffer): void {
  session.stdoutBuf += chunk.toString('utf8');
  let nl: number;
  while ((nl = session.stdoutBuf.indexOf('\n')) !== -1) {
    const line = session.stdoutBuf.slice(0, nl);
    session.stdoutBuf = session.stdoutBuf.slice(nl + 1);
    routeWarmLine(session, line);
  }
}

function routeWarmLine(session: WarmSession, line: string): void {
  const inflight = session.inflight;
  if (!inflight) return;
  const { isResult } = processStreamLine(line, inflight.cb);
  if (isResult) {
    finishWarmTurn(session, null);
  }
}

function finishWarmTurn(session: WarmSession, error: Error | null): void {
  const inflight = session.inflight;
  if (!inflight) return;
  clearTimeout(inflight.timer);
  session.inflight = undefined;
  if (error) {
    inflight.reject(error);
  } else {
    const text = (inflight.cb.finalText.value || inflight.cb.accumulated.value).trim();
    inflight.resolve({ text });
  }
}

function onWarmExit(session: WarmSession, code: number | null, err: Error | null): void {
  if (session.exited) return;
  session.exited = true;
  for (const [key, s] of warmSessions) {
    if (s === session) {
      warmSessions.delete(key);
      break;
    }
  }
  const tail = session.stderr.slice(-500);
  if (err) {
    log.warn({ err: err.message, sessionId: session.sessionId }, 'warm claude session errored');
  } else if (code !== 0) {
    log.warn({ code, sessionId: session.sessionId, stderrTail: tail }, 'warm claude session closed non-zero');
  } else {
    log.info({ sessionId: session.sessionId }, 'warm claude session closed');
  }
  if (session.inflight) {
    const reason = err?.message ?? `claude CLI exited ${code}: ${tail}`;
    finishWarmTurn(session, new Error(reason));
  }
}

async function claudeRunTurnWarm(opts: RunTurnOptions): Promise<RunTurnResult> {
  const key = opts.sessionKey;
  if (!key) {
    throw new Error('warm mode requires sessionKey');
  }

  let session = warmSessions.get(key);
  const fingerprint = fingerprintSpawn(opts);
  if (session && (session.exited || session.systemPromptFingerprint !== fingerprint)) {
    try { session.child.kill('SIGTERM'); } catch {}
    warmSessions.delete(key);
    session = undefined;
  }
  if (!session) {
    session = spawnWarmSession(opts);
    warmSessions.set(key, session);
  }
  if (session.inflight) {
    throw new Error(`claude warm session ${key} is busy`);
  }

  const cb: StreamCallbacks = {
    onChunk: opts.onChunk,
    onEvent: opts.onEvent,
    accumulated: { value: '' },
    finalText: { value: '' },
    emittedToolUse: new Set(),
    emittedToolResult: new Set(),
  };

  return new Promise<RunTurnResult>((resolve, reject) => {
    const timer = setTimeout(() => {
      finishWarmTurn(session!, new Error('claude warm turn timeout'));
      try { session!.child.kill('SIGKILL'); } catch {}
    }, WARM_TURN_TIMEOUT_MS);
    timer.unref?.();

    session!.inflight = { cb, resolve, reject, timer };

    const userMessage = {
      type: 'user',
      message: {
        role: 'user',
        content: [{ type: 'text', text: opts.userMessage }],
      },
    };
    try {
      session!.child.stdin.write(JSON.stringify(userMessage) + '\n');
    } catch (err) {
      finishWarmTurn(session!, err as Error);
    }
  });
}

export function closeWarmSessions(): void {
  for (const session of warmSessions.values()) {
    try { session.child.kill('SIGTERM'); } catch {}
  }
  warmSessions.clear();
}

export function dropWarmSession(sessionKey: string): boolean {
  const session = warmSessions.get(sessionKey);
  if (!session) return false;
  try { session.child.kill('SIGTERM'); } catch {}
  warmSessions.delete(sessionKey);
  return true;
}

export function warmSessionCount(): number {
  return warmSessions.size;
}

// ---------- public entry ----------

export async function claudeRunTurn(opts: RunTurnOptions): Promise<RunTurnResult> {
  if (opts.warm && opts.sessionKey) {
    return claudeRunTurnWarm(opts);
  }
  return claudeRunTurnCold(opts);
}
