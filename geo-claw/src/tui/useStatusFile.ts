import { useEffect, useRef, useState } from 'react';
import fs from 'node:fs';
import path from 'node:path';

export type ConnectorUiState = 'connected' | 'connecting' | 'disconnected' | 'error';

export type StatusSnapshot = {
  mcpConnected: boolean;
  whatsapp: ConnectorUiState;
  gmail: ConnectorUiState;
  telegram: ConnectorUiState;
  cronsCount: number;
};

const DEFAULTS: StatusSnapshot = {
  mcpConnected: false,
  whatsapp: 'disconnected',
  gmail: 'disconnected',
  telegram: 'disconnected',
  cronsCount: 0,
};

function mapState(raw: unknown): ConnectorUiState {
  if (typeof raw !== 'string') return 'disconnected';
  switch (raw) {
    case 'connected':
      return 'connected';
    case 'connecting':
    case 'qr':
    case 'authorizing':
      return 'connecting';
    case 'error':
      return 'error';
    default:
      return 'disconnected';
  }
}

function pickConnector(
  primary: Record<string, unknown> | undefined,
  legacy: Record<string, unknown> | undefined,
  id: string,
): ConnectorUiState {
  const fromPrimary = primary && (primary[id] as Record<string, unknown> | undefined);
  if (fromPrimary && typeof fromPrimary.state === 'string') return mapState(fromPrimary.state);
  if (legacy && typeof legacy.state === 'string') return mapState(legacy.state);
  return 'disconnected';
}

function parse(raw: string): StatusSnapshot {
  try {
    const obj = JSON.parse(raw) as Record<string, unknown>;
    const mcp = obj.mcp as { connected?: boolean } | undefined;
    const connectors = obj.connectors as Record<string, Record<string, unknown>> | undefined;
    const legacyWhatsapp = obj.whatsapp as Record<string, unknown> | undefined;
    const legacyGmail = obj.gmail as Record<string, unknown> | undefined;
    const legacyTelegram = obj.telegram as Record<string, unknown> | undefined;
    const crons = Array.isArray(obj.crons) ? obj.crons : [];
    return {
      mcpConnected: mcp?.connected === true,
      whatsapp: pickConnector(connectors, legacyWhatsapp, 'whatsapp'),
      gmail: pickConnector(connectors, legacyGmail, 'gmail'),
      telegram: pickConnector(connectors, legacyTelegram, 'telegram'),
      cronsCount: crons.length,
    };
  } catch {
    return DEFAULTS;
  }
}

export function useStatusFile(statusFilePath: string): StatusSnapshot {
  const [snapshot, setSnapshot] = useState<StatusSnapshot>(DEFAULTS);
  const debounceRef = useRef<NodeJS.Timeout | null>(null);

  useEffect(() => {
    let cancelled = false;

    let sawFile = false;

    const read = (): void => {
      fs.promises
        .readFile(statusFilePath, 'utf8')
        .then((raw) => {
          if (cancelled) return;
          sawFile = true;
          setSnapshot(parse(raw));
        })
        .catch((err: NodeJS.ErrnoException) => {
          if (cancelled) return;
          if (err && err.code === 'ENOENT' && sawFile) return;
          setSnapshot(DEFAULTS);
        });
    };

    const scheduleRead = (): void => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
      debounceRef.current = setTimeout(read, 50);
    };

    read();

    let fileWatcher: fs.FSWatcher | null = null;
    let dirWatcher: fs.FSWatcher | null = null;
    const dir = path.dirname(statusFilePath);
    const base = path.basename(statusFilePath);

    const startFileWatch = (): boolean => {
      try {
        fileWatcher = fs.watch(statusFilePath, () => scheduleRead());
        fileWatcher.on('error', () => {
          if (fileWatcher) {
            try { fileWatcher.close(); } catch {}
            fileWatcher = null;
          }
          startDirWatch();
        });
        return true;
      } catch {
        return false;
      }
    };

    function startDirWatch(): void {
      if (dirWatcher || cancelled) return;
      try {
        dirWatcher = fs.watch(dir, (_evt, filename) => {
          if (filename !== base) return;
          scheduleRead();
          if (!fileWatcher && startFileWatch() && dirWatcher) {
            try { dirWatcher.close(); } catch {}
            dirWatcher = null;
          }
        });
        dirWatcher.on('error', () => {});
      } catch {}
    }

    if (!startFileWatch()) startDirWatch();

    return () => {
      cancelled = true;
      if (debounceRef.current) clearTimeout(debounceRef.current);
      if (fileWatcher) { try { fileWatcher.close(); } catch {} }
      if (dirWatcher) { try { dirWatcher.close(); } catch {} }
    };
  }, [statusFilePath]);

  return snapshot;
}
