import net from 'node:net';
import fs from 'node:fs';
import { EventEmitter } from 'node:events';
import readline from 'node:readline';
import { paths } from '../config.js';
import { log } from '../log.js';
import { getToken, setToken } from '../keychain.js';
import type { StatusWriter } from '../types.js';

type Pending = {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: NodeJS.Timeout;
};

export type McpNotification = {
  jsonrpc: '2.0';
  method: string;
  params?: unknown;
};

type JsonRpcMessage = {
  jsonrpc?: '2.0';
  id?: number | string | null;
  method?: string;
  params?: unknown;
  result?: unknown;
  error?: { code?: number; message?: string; data?: unknown };
};

const BACKOFF_STEPS_MS = [1000, 2000, 4000, 8000, 16000, 30000];
const REQUEST_TIMEOUT_MS = 30_000;
const INIT_REQUEST_ID = 1;

async function loadAuthToken(): Promise<string | null> {
  const fromKc = await getToken('mcp');
  if (fromKc) return fromKc;
  try {
    if (fs.existsSync(paths.bootstrapTokenFile)) {
      const raw = fs.readFileSync(paths.bootstrapTokenFile, 'utf8').trim();
      if (raw.length > 0) {
        await setToken('mcp', raw);
        try {
          fs.unlinkSync(paths.bootstrapTokenFile);
        } catch {
        }
        return raw;
      }
    }
  } catch (err) {
    log.warn({ err: (err as Error).message }, 'failed reading bootstrap token');
  }
  return null;
}

export class McpClient extends EventEmitter {
  private socket: net.Socket | null = null;
  private rl: readline.Interface | null = null;
  private nextId = INIT_REQUEST_ID + 1;
  private pending = new Map<number, Pending>();
  private connected = false;
  private initialized = false;
  private stopping = false;
  private backoffIndex = 0;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private status: StatusWriter;

  constructor(status: StatusWriter) {
    super();
    this.status = status;
  }

  isConnected(): boolean {
    return this.connected && this.initialized;
  }

  start(): void {
    this.stopping = false;
    void this.connectLoop();
  }

  stop(): void {
    this.stopping = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    const sock = this.socket;
    this.socket = null;
    this.rl = null;
    this.connected = false;
    this.initialized = false;
    if (sock) {
      try {
        sock.destroy();
      } catch {
      }
    }
    this.rejectAllPending(new Error('client stopped'));
    this.status.updateMcp({ connected: false });
  }

  private rejectAllPending(err: Error): void {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
  }

  private scheduleReconnect(reason: string): void {
    if (this.stopping) return;
    if (this.reconnectTimer) return;
    const delay = BACKOFF_STEPS_MS[Math.min(this.backoffIndex, BACKOFF_STEPS_MS.length - 1)];
    this.backoffIndex = Math.min(this.backoffIndex + 1, BACKOFF_STEPS_MS.length - 1);
    log.warn({ reason, delay }, 'mcp reconnect scheduled');
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connectLoop();
    }, delay);
    this.reconnectTimer.unref?.();
  }

  private async connectLoop(): Promise<void> {
    if (this.stopping) return;

    const token = await loadAuthToken();
    if (!token) {
      this.status.updateMcp({ connected: false, error: 'missing-auth-token' });
      this.scheduleReconnect('missing-auth-token');
      return;
    }

    if (!fs.existsSync(paths.mcpSocket)) {
      this.status.updateMcp({ connected: false, error: 'socket-missing' });
      this.scheduleReconnect('socket-missing');
      return;
    }

    log.info({ socket: paths.mcpSocket }, 'mcp connecting');
    const socket = net.createConnection({ path: paths.mcpSocket });
    this.socket = socket;
    const rl = readline.createInterface({ input: socket, crlfDelay: Infinity });
    this.rl = rl;

    let initResolved = false;

    const handleClose = (reason: string): void => {
      if (this.socket !== socket) return;
      this.connected = false;
      this.initialized = false;
      this.socket = null;
      this.rl = null;
      this.rejectAllPending(new Error('mcp disconnected'));
      this.status.updateMcp({ connected: false, error: reason });
      this.emit('disconnected', reason);
      this.scheduleReconnect(reason);
    };

    socket.on('connect', () => {
      this.connected = true;
      log.info('mcp socket connected; sending initialize');
      try {
        this.sendRaw({
          jsonrpc: '2.0',
          id: INIT_REQUEST_ID,
          method: 'initialize',
          params: { authToken: token, clientName: 'geo-claw', clientVersion: '0.1.0' },
        });
      } catch (err) {
        log.error({ err: (err as Error).message }, 'mcp initialize send failed');
      }
    });

    socket.on('error', (err) => {
      log.error({ err: err.message }, 'mcp socket error');
    });

    socket.on('close', () => {
      handleClose(initResolved ? 'closed' : 'closed-before-init');
    });

    rl.on('line', (line) => {
      if (!line) return;
      let msg: JsonRpcMessage;
      try {
        msg = JSON.parse(line) as JsonRpcMessage;
      } catch (err) {
        log.warn({ err: (err as Error).message, len: line.length }, 'mcp parse error');
        return;
      }

      if (!this.initialized) {
        if (msg.id === INIT_REQUEST_ID && msg.result !== undefined) {
          this.initialized = true;
          initResolved = true;
          this.backoffIndex = 0;
          this.status.updateMcp({
            connected: true,
            lastTickAt: new Date().toISOString(),
            error: undefined,
          });
          log.info('mcp initialize ok');
          this.emit('connected');
          return;
        }
        if (msg.id === INIT_REQUEST_ID && msg.error) {
          log.error({ error: msg.error }, 'mcp initialize failed');
          try {
            socket.destroy();
          } catch {
          }
          return;
        }
        return;
      }

      this.handleMessage(msg);
    });
  }

  private handleMessage(msg: JsonRpcMessage): void {
    if (msg.id !== undefined && msg.id !== null && (msg.result !== undefined || msg.error !== undefined)) {
      const id = typeof msg.id === 'number' ? msg.id : Number(msg.id);
      const pending = this.pending.get(id);
      if (!pending) return;
      this.pending.delete(id);
      clearTimeout(pending.timer);
      if (msg.error) {
        pending.reject(new Error(msg.error.message ?? 'mcp error'));
      } else {
        pending.resolve(msg.result);
      }
      return;
    }

    if (typeof msg.method === 'string' && msg.id === undefined) {
      this.status.updateMcp({ connected: true, lastTickAt: new Date().toISOString() });
      const notif: McpNotification = {
        jsonrpc: '2.0',
        method: msg.method,
        params: msg.params,
      };
      this.emit('notification', notif);
    }
  }

  private sendRaw(obj: unknown): void {
    const sock = this.socket;
    if (!sock || !this.connected) {
      throw new Error('mcp not connected');
    }
    sock.write(JSON.stringify(obj) + '\n');
  }

  call(method: string, params?: unknown): Promise<unknown> {
    return new Promise((resolve, reject) => {
      if (!this.isConnected()) {
        reject(new Error('mcp not connected'));
        return;
      }
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`mcp call timeout: ${method}`));
      }, REQUEST_TIMEOUT_MS);
      timer.unref?.();
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.sendRaw({ jsonrpc: '2.0', id, method, params });
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err as Error);
      }
    });
  }
}
