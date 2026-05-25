import './bootEnv.js';
import fs from 'node:fs';
import path from 'node:path';
import chokidar from 'chokidar';
import { ensureDirs, paths } from './config.js';
import { log } from './log.js';
import { createStatusWriter } from './status.js';
import { appendMessage, clearChannel, closeDb, listChannels, loadHistory } from './store/db.js';
import { McpClient } from './mcp/client.js';
import { McpToolRegistry } from './mcp/tools.js';
import { GeoSubscription } from './mcp/subscribe.js';
import { createLLMLoop } from './llm/provider.js';
import { closeWarmSessions } from './llm/claude.js';
import { ensureCodexConfig } from './llm/codexConfig.js';
import { createWhatsappAdapter, type WhatsappAdapter } from './adapters/whatsapp/index.js';
import { createGmailAdapter, type GmailAdapter } from './adapters/gmail/index.js';
import { createTelegramAdapter, type TelegramAdapter } from './adapters/telegram/index.js';
import { startCronRegistry } from './cron/registry.js';
import { startIpcServer, type IpcServer } from './claw/ipc.js';
import { getToken } from './keychain.js';
import type { LLMLoop, ProviderId, StatusWriter } from './types.js';

export type { LLMLoop, ChannelContext, StatusWriter, ConnectorId, ConnectorState } from './types.js';
export { paths, MODELS, KEYCHAIN_SERVICE } from './config.js';
export { log } from './log.js';
export { createLLMLoop } from './llm/provider.js';
export { createStatusWriter } from './status.js';

export type Daemon = {
  llm: LLMLoop;
  mcp: McpClient;
  whatsapp: WhatsappAdapter;
  gmail: GmailAdapter;
  telegram: TelegramAdapter;
  cron: { stop: () => void };
  status: StatusWriter;
  shutdown: () => Promise<void>;
};

let ipcServer: IpcServer | null = null;

export function createDaemon(): Daemon {
  ensureDirs();
  ensureCodexConfig();

  const status = createStatusWriter();
  const mcp = new McpClient(status);
  const toolRegistry = new McpToolRegistry(mcp);
  const subscription = new GeoSubscription(mcp);
  void subscription;

  mcp.start();

  const llm = createLLMLoop({ mcpClient: mcp, toolRegistry });
  const gmail = createGmailAdapter({ llm, status });
  const telegram = createTelegramAdapter({ llm, status });
  const whatsapp = createWhatsappAdapter({ llm, status, mcp, telegram });

  const sendWhatsappToSelf = async (text: string): Promise<void> => {
    await whatsapp.sendToSelf(text);
  };

  startIpcServer({
    'whatsapp.send_to_self': async (params) => {
      const text = (params as { text?: unknown }).text;
      if (typeof text !== 'string' || text.length === 0) {
        throw new Error('text must be a non-empty string');
      }
      return whatsapp.sendToSelf(text);
    },
    'conversations.list_channels': async (params) => {
      const p = (params as { prefix?: unknown; limit?: unknown }) ?? {};
      const prefix = typeof p.prefix === 'string' ? p.prefix : '';
      const limit = typeof p.limit === 'number' ? p.limit : 50;
      return listChannels(prefix, limit);
    },
    'conversations.get_history': async (params) => {
      const p = (params as { channelId?: unknown; limit?: unknown }) ?? {};
      const channelId = typeof p.channelId === 'string' ? p.channelId : '';
      if (!channelId) throw new Error('channelId must be a non-empty string');
      const limit = typeof p.limit === 'number' ? p.limit : 20;
      return loadHistory(channelId, limit);
    },
    'llm.run_turn': async (params, ctx) => {
      const p = (params as { channelId?: unknown; userText?: unknown }) ?? {};
      const channelId = typeof p.channelId === 'string' && p.channelId.length > 0 ? p.channelId : 'main';
      const userText = typeof p.userText === 'string' ? p.userText : '';
      if (userText.length === 0) throw new Error('userText must be a non-empty string');
      const fullChannelId = `nano:${channelId}`;
      appendMessage(fullChannelId, 'user', JSON.stringify({ text: userText }));
      const turn = await llm.runTurn(
        { channelKind: 'nano', channelId, fromName: 'Gabriel' },
        userText,
        {
          onEvent: (event) => ctx.pushEvent(event as unknown as Record<string, unknown>),
        },
      );
      if (turn.reply) {
        appendMessage(fullChannelId, 'assistant', JSON.stringify({ text: turn.reply }));
      }
      return { reply: turn.reply };
    },
  })
    .then((srv) => {
      ipcServer = srv;
    })
    .catch((err) => {
      log.error({ err: (err as Error).message }, 'claw-ipc:start-failed');
    });

  const cronRegistry = startCronRegistry({
    status,
    sendTelegram: telegram.sendToOwner,
    sendWhatsappToSelf,
  });

  const shutdown = async () => {
    log.info('shutting down');
    try {
      cronRegistry.stop();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error stopping cron');
    }
    try {
      if (ipcServer) await ipcServer.close();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error stopping claw-ipc');
    }
    try {
      await whatsapp.stop();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error stopping whatsapp');
    }
    try {
      await gmail.stop();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error stopping gmail');
    }
    try {
      await telegram.stop();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error stopping telegram');
    }
    try {
      mcp.stop();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error stopping mcp');
    }
    try {
      closeWarmSessions();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error closing warm claude sessions');
    }
    try {
      status.flush();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error flushing status');
    }
    try {
      closeDb();
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'error closing db');
    }
  };

  return { llm, mcp, whatsapp, gmail, telegram, cron: cronRegistry, status, shutdown };
}

async function whatsappHasSession(): Promise<boolean> {
  try {
    const credsPath = path.join(paths.authWhatsapp, 'creds.json');
    const stat = await fs.promises.stat(credsPath);
    return stat.isFile() && stat.size > 0;
  } catch {
    return false;
  }
}

async function gmailHasRefreshToken(): Promise<boolean> {
  const token = await getToken('gmail-refresh');
  return token !== null && token.length > 0;
}

const KNOWN_SIGNALS = new Set([
  'request-pair-whatsapp',
  'disconnect-whatsapp',
  'request-auth-gmail',
  'disconnect-gmail',
  'request-pair-telegram',
  'disconnect-telegram',
  'set-provider:claude',
  'set-provider:codex',
]);

function isKnownSignal(name: string): boolean {
  if (KNOWN_SIGNALS.has(name)) return true;
  if (name.startsWith('add-job:')) return true;
  if (name.startsWith('remove-job:')) return true;
  return false;
}

const IGNORED_SIGNAL_FILES = new Set(['qr.png', 'qr.txt', 'bootstrap-token', 'telegram-token']);

async function persistProviderEnv(provider: ProviderId): Promise<void> {
  const envPath = paths.envFile;
  let lines: string[] = [];
  try {
    const raw = await fs.promises.readFile(envPath, 'utf8');
    lines = raw.split('\n').filter((l) => l.length > 0 && !l.startsWith('GEO_CLAW_PROVIDER='));
  } catch {}
  lines.push(`GEO_CLAW_PROVIDER=${provider}`);
  await fs.promises.mkdir(path.dirname(envPath), { recursive: true });
  await fs.promises.writeFile(envPath, lines.join('\n') + '\n', 'utf8');
}

function watchSignals(daemon: Daemon): chokidar.FSWatcher {
  const watcher = chokidar.watch(paths.signalsDir, {
    ignoreInitial: true,
    depth: 0,
    persistent: true,
    awaitWriteFinish: { stabilityThreshold: 150, pollInterval: 50 },
  });

  const consume = async (file: string) => {
    const name = path.basename(file);
    if (IGNORED_SIGNAL_FILES.has(name)) return;
    if (name.startsWith('.') || name.endsWith('.tmp')) return;
    if (!isKnownSignal(name)) {
      log.warn({ signal: name }, 'unknown signal, ignoring');
      try {
        await fs.promises.unlink(file);
      } catch {}
      return;
    }
    log.info({ signal: name }, 'signal received');
    try {
      if (name.startsWith('add-job:')) {
        const id = name.slice('add-job:'.length);
        log.info({ id }, 'add-job signal — spec drop expected in jobsDir');
      } else if (name.startsWith('remove-job:')) {
        const id = name.slice('remove-job:'.length);
        const target = path.join(paths.jobsDir, `${id}.json`);
        try {
          await fs.promises.unlink(target);
          log.info({ id }, 'removed job spec');
        } catch (err) {
          log.warn({ id, err: (err as Error).message }, 'remove-job: unlink failed');
        }
      } else if (name === 'set-provider:claude' || name === 'set-provider:codex') {
        const provider: ProviderId = name === 'set-provider:codex' ? 'codex' : 'claude';
        process.env.GEO_CLAW_PROVIDER = provider;
        try {
          await persistProviderEnv(provider);
        } catch (err) {
          log.warn({ err: (err as Error).message }, 'persist provider env failed');
        }
        daemon.status.setProvider(provider);
        log.info({ provider }, 'provider switched');
      } else {
        switch (name) {
          case 'request-pair-whatsapp':
            await daemon.whatsapp.reset();
            break;
          case 'disconnect-whatsapp':
            await daemon.whatsapp.stop();
            break;
          case 'request-auth-gmail':
            await daemon.gmail.authorize();
            break;
          case 'disconnect-gmail':
            await daemon.gmail.stop();
            break;
          case 'request-pair-telegram': {
            const tokenPath = paths.telegramTokenSignal;
            let token = '';
            try {
              token = (await fs.promises.readFile(tokenPath, 'utf8')).trim();
            } catch (err) {
              log.error({ err: (err as Error).message }, 'request-pair-telegram: token file missing');
              break;
            }
            if (token.length === 0) {
              log.error('request-pair-telegram: token file empty');
              break;
            }
            try {
              await daemon.telegram.pair(token);
            } finally {
              try {
                await fs.promises.unlink(tokenPath);
              } catch {}
            }
            break;
          }
          case 'disconnect-telegram':
            await daemon.telegram.reset();
            break;
        }
      }
    } catch (err) {
      log.error({ signal: name, err: (err as Error).message }, 'signal handler failed');
    }
    try {
      await fs.promises.unlink(file);
    } catch {}
  };

  watcher.on('add', (file) => {
    void consume(file);
  });
  watcher.on('error', (err) => {
    log.error({ err: (err as Error).message }, 'signal watcher error');
  });
  return watcher;
}

async function main(): Promise<void> {
  const daemon = createDaemon();
  log.info({ paths: { logFile: paths.logFile, db: paths.dbFile, status: paths.statusFile } }, 'geo-claw boot');

  let shuttingDown = false;
  const handleSignal = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info({ signal }, 'signal received');
    void daemon.shutdown().then(() => {
      process.exit(0);
    });
  };
  process.on('SIGINT', () => handleSignal('SIGINT'));
  process.on('SIGTERM', () => handleSignal('SIGTERM'));
  process.on('unhandledRejection', (reason) => {
    const err = reason instanceof Error ? reason : new Error(String(reason));
    log.error({ err: err.message, stack: err.stack }, 'unhandledRejection');
  });
  process.on('uncaughtException', (err) => {
    log.error({ err: err.message, stack: err.stack }, 'uncaughtException');
  });

  const watcher = watchSignals(daemon);
  void watcher;

  if (await whatsappHasSession()) {
    log.info('whatsapp session found, starting');
    void daemon.whatsapp.start().catch((err) => {
      const msg = (err as Error).message;
      log.error({ err: msg }, 'whatsapp start failed');
      daemon.status.updateConnector('whatsapp', { state: 'error', error: msg });
    });
  } else {
    log.info('whatsapp not paired, awaiting request-pair-whatsapp signal');
  }

  if (await gmailHasRefreshToken()) {
    log.info('gmail refresh token found, starting');
    void daemon.gmail.start().catch((err) => {
      const msg = (err as Error).message;
      log.error({ err: msg }, 'gmail start failed');
      daemon.status.updateConnector('gmail', { state: 'error', error: msg });
    });
  } else {
    log.info('gmail not authorized, awaiting request-auth-gmail signal');
  }

  const telegramToken = await getToken('telegram-bot-token');
  if (telegramToken) {
    log.info('telegram bot token found, starting');
    void daemon.telegram.start().catch((err) => {
      const msg = (err as Error).message;
      log.error({ err: msg }, 'telegram start failed');
      daemon.status.updateConnector('telegram', { state: 'error', error: msg });
    });
  } else {
    log.info('telegram not paired, awaiting request-pair-telegram signal');
  }

  process.stdout.write('geo-claw running. Watching signals dir. Send SIGINT to quit.\n');
  setInterval(() => {}, 60_000);
}

const isMain =
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith('/dist/index.js') ||
  process.argv[1]?.endsWith('/src/index.ts');

if (isMain) {
  main().catch((err) => {
    log.error({ err: (err as Error).message, stack: (err as Error).stack }, 'fatal');
    process.exit(1);
  });
}
