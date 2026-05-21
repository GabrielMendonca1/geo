import { spawn } from 'node:child_process';
import { paths } from '../config.js';
import { log } from '../log.js';

export type RunTurnResult = { text: string; usage?: unknown };

const TIMEOUT_MS = 60_000;

type ClaudeJsonOutput = {
  result?: string;
  total_cost_usd?: number;
  usage?: unknown;
};

export async function claudeRunTurn(opts: {
  system: string;
  userMessage: string;
  model?: string;
  maxTurns?: number;
  withGeoMcp?: boolean;
}): Promise<RunTurnResult> {
  const mcpConfig = JSON.stringify({
    mcpServers: {
      geo: { command: paths.geoMcpBridge },
    },
  });

  const args = [
    '-p', opts.userMessage,
    '--output-format', 'json',
    '--max-turns', String(opts.maxTurns ?? 4),
    '--append-system-prompt', opts.system,
    '--model', opts.model ?? process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-opus-4-7',
  ];
  if (opts.withGeoMcp !== false) {
    args.push('--strict-mcp-config', '--mcp-config', mcpConfig);
  }

  const child = spawn('claude', args, {
    env: process.env,
  });

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
      reject(new Error('claude CLI timeout'));
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
    log.debug({ stderr: stderr.slice(-2000) }, 'claude:stderr');
  }

  if (exitCode !== 0) {
    throw new Error(`claude CLI exited ${exitCode}: ${stderr.slice(-500)}`);
  }

  let parsed: ClaudeJsonOutput;
  try {
    parsed = JSON.parse(stdout) as ClaudeJsonOutput;
  } catch (err) {
    throw new Error(`claude CLI returned non-JSON: ${(err as Error).message}: ${stdout.slice(0, 500)}`);
  }

  const text = (parsed.result ?? '').trim();
  return { text, usage: parsed.usage ?? { total_cost_usd: parsed.total_cost_usd } };
}
