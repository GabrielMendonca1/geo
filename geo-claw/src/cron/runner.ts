import { exec } from 'node:child_process';
import { promisify } from 'node:util';
import { log } from '../log.js';
import { claudeRunTurn } from '../llm/claude.js';
import { codexRunTurn } from '../llm/codex.js';
import type { CronStatus, ProviderId } from '../types.js';
import type { CronDeps, JobSpec, JobSink } from './registry.js';

const execAsync = promisify(exec);

function resolveProvider(): ProviderId {
  return process.env.GEO_CLAW_PROVIDER === 'codex' ? 'codex' : 'claude';
}

function escapeOsa(value: string): string {
  return value.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function buildStatus(
  spec: JobSpec,
  lastStatus: CronStatus['lastStatus'],
  error: string | null,
): CronStatus {
  return {
    id: spec.id,
    title: spec.title,
    cron: spec.cron,
    lastRun: new Date().toISOString(),
    lastStatus,
    error,
    sinks: spec.sinks,
  };
}

async function deliver(spec: JobSpec, sink: JobSink, text: string, deps: CronDeps): Promise<void> {
  if (sink === 'telegram') {
    await deps.sendTelegram(text);
    return;
  }
  if (sink === 'whatsapp') {
    await deps.sendWhatsappToSelf(text);
    return;
  }
  if (sink === 'notification') {
    const body = escapeOsa(text);
    const title = escapeOsa(`Nano: ${spec.title}`);
    await execAsync(`osascript -e 'display notification "${body}" with title "${title}"'`);
    return;
  }
}

export async function runJob(spec: JobSpec, deps: CronDeps): Promise<void> {
  const system = `You are running as a scheduled job titled '${spec.title}'. Output is delivered to user's channels. Be concise (3 lines max). No markdown formatting.`;
  const provider = resolveProvider();

  let text: string;
  try {
    const result =
      provider === 'codex'
        ? await codexRunTurn({ system, userMessage: spec.prompt })
        : await claudeRunTurn({ system, userMessage: spec.prompt });
    text = result.text.trim();
  } catch (err) {
    const msg = (err as Error).message;
    log.error({ err: msg, id: spec.id, provider }, 'cron: llm call failed');
    deps.status.upsertCron(buildStatus(spec, 'error', msg));
    return;
  }

  if (text.length === 0) {
    log.info({ id: spec.id }, 'cron: empty llm output, skipping sinks');
    deps.status.upsertCron(buildStatus(spec, 'ok', null));
    return;
  }

  const errors: string[] = [];
  for (const sink of spec.sinks) {
    try {
      await deliver(spec, sink, text, deps);
    } catch (err) {
      const msg = (err as Error).message;
      log.error({ err: msg, id: spec.id, sink }, 'cron: sink delivery failed');
      errors.push(`${sink}: ${msg}`);
    }
  }

  if (errors.length === 0) {
    deps.status.upsertCron(buildStatus(spec, 'ok', null));
  } else {
    deps.status.upsertCron(buildStatus(spec, 'error', errors.join('; ')));
  }
}
