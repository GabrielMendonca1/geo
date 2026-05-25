import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { paths } from '../config.js';
import { log } from '../log.js';

export type IpcRequestCtx = {
  id: string | number | null;
  pushEvent: (event: Record<string, unknown>) => void;
};
export type IpcHandler = (params: unknown, ctx: IpcRequestCtx) => Promise<unknown>;
export type IpcHandlers = Record<string, IpcHandler>;

export type IpcServer = { close: () => Promise<void> };

export async function startIpcServer(handlers: IpcHandlers): Promise<IpcServer> {
  const sockPath = paths.clawIpcSocket;
  await fs.promises.mkdir(path.dirname(sockPath), { recursive: true });
  try {
    await fs.promises.unlink(sockPath);
  } catch {}

  const server = net.createServer((conn) => {
    let buf = '';
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      let nl: number;
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line.trim()) continue;
        void handleLine(line, conn, handlers);
      }
    });
    conn.on('error', (err) => {
      log.warn({ err: err.message }, 'claw-ipc:conn-error');
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(sockPath, () => {
      server.off('error', reject);
      resolve();
    });
  });

  log.info({ sockPath }, 'claw-ipc:listening');

  return {
    close: () =>
      new Promise<void>((resolve) => {
        server.close(() => resolve());
      }),
  };
}

async function handleLine(line: string, conn: net.Socket, handlers: IpcHandlers): Promise<void> {
  let msg: { id?: unknown; method?: unknown; params?: unknown };
  try {
    msg = JSON.parse(line);
  } catch (err) {
    conn.write(JSON.stringify({ id: null, error: `invalid json: ${(err as Error).message}` }) + '\n');
    return;
  }
  const id = (msg.id ?? null) as string | number | null;
  const method = typeof msg.method === 'string' ? msg.method : '';
  const handler = handlers[method];
  if (!handler) {
    conn.write(JSON.stringify({ id, error: `unknown method: ${method}` }) + '\n');
    return;
  }
  try {
    const result = await handler(msg.params ?? {});
    conn.write(JSON.stringify({ id, result }) + '\n');
  } catch (err) {
    conn.write(JSON.stringify({ id, error: (err as Error).message }) + '\n');
  }
}

export function ipcCall(method: string, params: unknown, timeoutMs = 15_000): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const conn = net.createConnection(paths.clawIpcSocket);
    let buf = '';
    let settled = false;
    const settle = (fn: () => void) => {
      if (settled) return;
      settled = true;
      try { conn.end(); } catch {}
      fn();
    };
    const timer = setTimeout(() => {
      settle(() => reject(new Error(`ipc timeout calling ${method}`)));
    }, timeoutMs);
    timer.unref?.();
    conn.on('connect', () => {
      conn.write(JSON.stringify({ id: 1, method, params }) + '\n');
    });
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf8');
      const nl = buf.indexOf('\n');
      if (nl === -1) return;
      const line = buf.slice(0, nl);
      clearTimeout(timer);
      try {
        const resp = JSON.parse(line) as { result?: unknown; error?: string };
        if (resp.error) {
          settle(() => reject(new Error(resp.error)));
        } else {
          settle(() => resolve(resp.result));
        }
      } catch (err) {
        settle(() => reject(new Error(`invalid ipc response: ${(err as Error).message}`)));
      }
    });
    conn.on('error', (err) => {
      clearTimeout(timer);
      settle(() => reject(err));
    });
  });
}
