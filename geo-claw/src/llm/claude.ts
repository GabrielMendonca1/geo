import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { paths } from '../config.js';
import { log } from '../log.js';

export type RunTurnResult = { text: string; usage?: unknown };
export type RunTurnOptions = {
  system: string;
  userMessage: string;
  sessionKey?: string;
  onChunk?: (delta: string) => void;
  model?: string;
  maxTurns?: number;
  withGeoMcp?: boolean;
};

const TIMEOUT_MS = 60_000;
const MAX_STDOUT_BYTES = 10 * 1024 * 1024;

const sessionByKey = new Map<string, string>();

function getSessionId(key: string): { id: string; isFirst: boolean } {
  const existing = sessionByKey.get(key);
  if (existing) return { id: existing, isFirst: false };
  const id = randomUUID();
  sessionByKey.set(key, id);
  return { id, isFirst: true };
}

export async function claudeRunTurn(opts: RunTurnOptions): Promise<RunTurnResult> {
  const mcpConfig = JSON.stringify({
    mcpServers: { geo: { command: paths.geoMcpBridge } },
  });

  const { id: sessionId, isFirst } = getSessionId(opts.sessionKey);

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
    '--effort', process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'medium',
  ];
  if (opts.withGeoMcp !== false) {
    args.push('--strict-mcp-config', '--mcp-config', mcpConfig);
  }

  const child = spawn('claude', args, { env: process.env });

  let stdoutBuf = '';
  let stdoutBytes = 0;
  let stderr = '';
  let accumulated = '';
  let finalText = '';
  let aborted = false;

  const processLine = (line: string): void => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let evt: unknown;
    try {
      evt = JSON.parse(trimmed);
    } catch {
      return;
    }
    const obj = evt as Record<string, unknown>;
    if (obj.type === 'stream_event') {
      const event = obj.event as Record<string, unknown> | undefined;
      if (event?.type === 'content_block_delta') {
        const delta = event.delta as Record<string, unknown> | undefined;
        if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
          accumulated += delta.text;
          opts.onChunk?.(delta.text);
        }
      }
      return;
    }
    if (obj.type === 'result' && typeof obj.result === 'string') {
      finalText = obj.result;
    }
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
      processLine(line);
    }
  });
  child.stderr.on('data', (chunk: Buffer) => {
    stderr += chunk.toString('utf8');
  });

  const exitCode: number = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch {}
      reject(new Error('claude CLI timeout'));
    }, TIMEOUT_MS);
    timer.unref?.();
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (stdoutBuf.trim()) processLine(stdoutBuf);
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
    sessionByKey.delete(opts.sessionKey);
    throw new Error(`claude CLI exited ${exitCode}: ${stderr.slice(-500)}`);
  }

  const text = (finalText || accumulated).trim();
  return { text };
}
