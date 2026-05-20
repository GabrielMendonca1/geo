import fs from 'node:fs';
import path from 'node:path';
import chokidar from 'chokidar';
import cron from 'node-cron';
import { paths } from '../config.js';
import { log } from '../log.js';
import type { CronStatus, StatusWriter } from '../types.js';
import { runJob } from './runner.js';

export type JobSink = 'telegram' | 'whatsapp' | 'notification';

export interface JobSpec {
  id: string;
  title: string;
  cron: string;
  prompt: string;
  sinks: JobSink[];
}

export interface CronDeps {
  status: StatusWriter;
  sendTelegram: (text: string) => Promise<void>;
  sendWhatsappToSelf: (text: string) => Promise<void>;
}

interface Entry {
  spec: JobSpec;
  task: cron.ScheduledTask | null;
  status: CronStatus;
}

const VALID_SINKS = new Set<JobSink>(['telegram', 'whatsapp', 'notification']);

function parseSpec(file: string): JobSpec | null {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    const data = JSON.parse(raw) as Partial<JobSpec>;
    if (typeof data.id !== 'string' || data.id.length === 0) return null;
    if (typeof data.title !== 'string' || data.title.length === 0) return null;
    if (typeof data.cron !== 'string' || data.cron.length === 0) return null;
    if (typeof data.prompt !== 'string' || data.prompt.length === 0) return null;
    if (!Array.isArray(data.sinks) || data.sinks.length === 0) return null;
    const sinks: JobSink[] = [];
    for (const s of data.sinks) {
      if (typeof s === 'string' && VALID_SINKS.has(s as JobSink)) sinks.push(s as JobSink);
    }
    if (sinks.length === 0) return null;
    return { id: data.id, title: data.title, cron: data.cron, prompt: data.prompt, sinks };
  } catch (err) {
    log.warn({ err: (err as Error).message, file }, 'cron: invalid spec');
    return null;
  }
}

function jobIdFromFile(file: string): string {
  return path.basename(file, '.json');
}

export function startCronRegistry(deps: CronDeps): { stop: () => void } {
  fs.mkdirSync(paths.jobsDir, { recursive: true });

  const entries = new Map<string, Entry>();

  function publish(): void {
    const list: CronStatus[] = [];
    for (const e of entries.values()) list.push(e.status);
    deps.status.setCrons(list);
  }

  function unschedule(id: string): void {
    const entry = entries.get(id);
    if (!entry) return;
    if (entry.task) {
      try {
        entry.task.stop();
      } catch (err) {
        log.warn({ err: (err as Error).message, id }, 'cron: stop task failed');
      }
    }
  }

  function load(file: string): void {
    const id = jobIdFromFile(file);
    unschedule(id);

    const spec = parseSpec(file);
    if (!spec) {
      entries.set(id, {
        spec: { id, title: id, cron: '', prompt: '', sinks: [] },
        task: null,
        status: {
          id,
          title: id,
          cron: '',
          lastRun: null,
          lastStatus: 'error',
          error: 'invalid spec',
          sinks: [],
        },
      });
      publish();
      return;
    }

    if (spec.id !== id) {
      log.warn({ fileId: id, specId: spec.id }, 'cron: spec id mismatch — using filename');
      spec.id = id;
    }

    const existing = entries.get(id);
    const prevStatus = existing?.status;

    if (!cron.validate(spec.cron)) {
      entries.set(id, {
        spec,
        task: null,
        status: {
          id: spec.id,
          title: spec.title,
          cron: spec.cron,
          lastRun: prevStatus?.lastRun ?? null,
          lastStatus: 'error',
          error: 'invalid cron',
          sinks: spec.sinks,
        },
      });
      publish();
      return;
    }

    const task = cron.schedule(spec.cron, () => {
      void runJob(spec, deps).catch((err) => {
        log.error({ err: (err as Error).message, id: spec.id }, 'cron: runJob unhandled');
      });
    });

    entries.set(id, {
      spec,
      task,
      status: {
        id: spec.id,
        title: spec.title,
        cron: spec.cron,
        lastRun: prevStatus?.lastRun ?? null,
        lastStatus: prevStatus?.lastStatus ?? 'never',
        error: null,
        sinks: spec.sinks,
      },
    });
    publish();
    log.info({ id: spec.id, cron: spec.cron }, 'cron: scheduled');
  }

  function remove(file: string): void {
    const id = jobIdFromFile(file);
    unschedule(id);
    entries.delete(id);
    publish();
    log.info({ id }, 'cron: removed');
  }

  try {
    for (const name of fs.readdirSync(paths.jobsDir)) {
      if (!name.endsWith('.json')) continue;
      load(path.join(paths.jobsDir, name));
    }
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'cron: initial scan failed');
  }

  const watcher = chokidar.watch(paths.jobsDir, {
    ignoreInitial: true,
    depth: 0,
    persistent: true,
    awaitWriteFinish: { stabilityThreshold: 150, pollInterval: 50 },
  });

  watcher.on('add', (file) => {
    if (file.endsWith('.json')) load(file);
  });
  watcher.on('change', (file) => {
    if (file.endsWith('.json')) load(file);
  });
  watcher.on('unlink', (file) => {
    if (file.endsWith('.json')) remove(file);
  });
  watcher.on('error', (err) => {
    log.error({ err: (err as Error).message }, 'cron: watcher error');
  });

  function stop(): void {
    for (const id of entries.keys()) unschedule(id);
    entries.clear();
    void watcher.close();
  }

  return { stop };
}
