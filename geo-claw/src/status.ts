import fs from 'node:fs';
import path from 'node:path';
import { paths } from './config.js';
import type {
  ConnectorId,
  ConnectorState,
  CronStatus,
  ProviderId,
  StatusFile,
  StatusWriter,
} from './types.js';

const DEBOUNCE_MS = 500;

function nowIso(): string {
  return new Date().toISOString();
}

function defaultConnector(): ConnectorState {
  return {
    state: 'disconnected',
    detail: null,
    identity: null,
    lastEventAt: null,
    error: null,
  };
}

function defaultProvider(): ProviderId {
  const env = process.env.GEO_CLAW_PROVIDER;
  return env === 'codex' ? 'codex' : 'claude';
}

function defaultStatus(): StatusFile {
  return {
    version: 2,
    updatedAt: nowIso(),
    provider: defaultProvider(),
    mcp: { connected: false, lastTickAt: null, error: null },
    connectors: {
      whatsapp: defaultConnector(),
      gmail: defaultConnector(),
      telegram: defaultConnector(),
    },
    crons: [],
  };
}

function normalizeConnector(patch: Partial<ConnectorState>, prev: ConnectorState): ConnectorState {
  const next: ConnectorState = { ...prev, ...patch };
  if (patch.state !== undefined || patch.detail !== undefined) {
    next.lastEventAt = nowIso();
  }
  if (next.detail === undefined) next.detail = null;
  if (next.identity === undefined) next.identity = null;
  if (next.lastEventAt === undefined) next.lastEventAt = null;
  if (next.error === undefined) next.error = null;
  return next;
}

export function createStatusWriter(): StatusWriter {
  let state: StatusFile = defaultStatus();
  let loadedExisting = false;
  try {
    const raw = fs.readFileSync(paths.statusFile, 'utf8');
    const parsed = JSON.parse(raw) as StatusFile;
    if (parsed && parsed.version === 2) {
      state = parsed;
      loadedExisting = true;
    }
  } catch {
  }
  let pending: NodeJS.Timeout | null = null;

  function persist(): void {
    state.updatedAt = nowIso();
    const tmp = `${paths.statusFile}.tmp.${process.pid}`;
    const data = JSON.stringify(state, null, 2);
    fs.mkdirSync(path.dirname(paths.statusFile), { recursive: true });
    fs.writeFileSync(tmp, data, 'utf8');
    fs.renameSync(tmp, paths.statusFile);
  }

  function flush(): void {
    if (pending) {
      clearTimeout(pending);
      pending = null;
    }
    try {
      persist();
    } catch {
    }
  }

  function schedule(immediate: boolean): void {
    if (immediate) {
      flush();
      return;
    }
    if (pending) return;
    pending = setTimeout(() => {
      pending = null;
      try {
        persist();
      } catch {
      }
    }, DEBOUNCE_MS);
    pending.unref?.();
  }

  if (!loadedExisting) flush();

  return {
    updateMcp(patch) {
      state.mcp = {
        connected: patch.connected ?? state.mcp.connected,
        lastTickAt: patch.lastTickAt !== undefined ? patch.lastTickAt : state.mcp.lastTickAt,
        error: patch.error !== undefined ? patch.error : state.mcp.error,
      };
      const immediate = patch.connected === false || patch.connected === true;
      schedule(immediate);
    },
    updateConnector(id: ConnectorId, patch: Partial<ConnectorState>) {
      state.connectors[id] = normalizeConnector(patch, state.connectors[id]);
      const immediate =
        patch.state === 'error' || patch.state === 'connected' || patch.state === 'disconnected';
      schedule(immediate);
    },
    setProvider(provider: ProviderId) {
      state.provider = provider;
      schedule(true);
    },
    setCrons(crons: CronStatus[]) {
      state.crons = crons;
      schedule(true);
    },
    upsertCron(cron: CronStatus) {
      const idx = state.crons.findIndex((c) => c.id === cron.id);
      if (idx === -1) state.crons.push(cron);
      else state.crons[idx] = cron;
      schedule(true);
    },
    removeCron(id: string) {
      state.crons = state.crons.filter((c) => c.id !== id);
      schedule(true);
    },
    snapshot() {
      return JSON.parse(JSON.stringify(state)) as StatusFile;
    },
    flush,
  };
}
