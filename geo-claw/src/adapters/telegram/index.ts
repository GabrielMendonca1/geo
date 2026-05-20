import { Bot, type Context } from 'grammy';
import { log } from '../../log.js';
import { getToken, setToken, deleteToken } from '../../keychain.js';
import type { ChannelContext, LLMLoop, StatusWriter } from '../../types.js';

export interface TelegramAdapter {
  start(): Promise<void>;
  stop(): Promise<void>;
  pair(botToken: string): Promise<void>;
  reset(): Promise<void>;
  sendToOwner(text: string): Promise<void>;
}

export interface TelegramAdapterDeps {
  llm: LLMLoop;
  status: StatusWriter;
}

const KEYCHAIN_BOT_TOKEN = 'telegram-bot-token';
const KEYCHAIN_OWNER_ID = 'telegram-owner-id';

export function createTelegramAdapter(deps: TelegramAdapterDeps): TelegramAdapter {
  const { llm, status } = deps;

  let bot: Bot | null = null;
  let ownerId: string | null = null;
  let identity: string | null = null;

  async function handleMessage(ctx: Context): Promise<void> {
    const fromId = ctx.from?.id;
    const text = ctx.message?.text;
    if (!fromId || !text || !ctx.chat) return;

    const fromIdStr = String(fromId);

    if (ownerId === null) {
      ownerId = fromIdStr;
      try {
        await setToken(KEYCHAIN_OWNER_ID, fromIdStr);
      } catch (err) {
        log.warn({ err: (err as Error).message }, 'telegram: persist owner id failed');
      }
      identity = ctx.from?.username ? `@${ctx.from.username}` : ctx.from?.first_name ?? fromIdStr;
      status.updateConnector('telegram', {
        state: 'connected',
        identity,
        detail: null,
        error: null,
      });
      log.info({ ownerId: fromIdStr, identity }, 'telegram: owner paired');
    } else if (fromIdStr !== ownerId) {
      log.warn({ fromId: fromIdStr, ownerId }, 'telegram: ignoring message from non-owner');
      return;
    }

    const channelCtx: ChannelContext = {
      channelId: String(ctx.chat.id),
      channelKind: 'telegram',
      fromName: ctx.from?.username ?? ctx.from?.first_name,
    };

    try {
      const turn = await llm.runTurn(channelCtx, text);
      if (turn.reply) {
        await ctx.reply(turn.reply);
      }
      status.updateConnector('telegram', { lastEventAt: new Date().toISOString() });
    } catch (err) {
      log.error({ err: (err as Error).message }, 'telegram: handler failed');
      try {
        await ctx.reply('Sorry, error');
      } catch (replyErr) {
        log.warn({ err: (replyErr as Error).message }, 'telegram: reply after error failed');
      }
    }
  }

  async function start(): Promise<void> {
    if (bot) return;
    const token = await getToken(KEYCHAIN_BOT_TOKEN);
    if (!token) {
      status.updateConnector('telegram', {
        state: 'disconnected',
        detail: 'no bot token — drop one via signals/telegram-token then request-pair-telegram',
      });
      return;
    }

    ownerId = await getToken(KEYCHAIN_OWNER_ID);
    status.updateConnector('telegram', {
      state: 'connecting',
      detail: ownerId ? 'starting' : 'awaiting first /start',
      error: null,
    });

    const newBot = new Bot(token);
    newBot.on('message:text', handleMessage);
    newBot.catch((err) => {
      log.error({ err: (err.error as Error)?.message ?? String(err.error) }, 'telegram: bot error');
    });

    try {
      const me = await newBot.api.getMe();
      identity = me.username ? `@${me.username}` : me.first_name;
    } catch (err) {
      const msg = (err as Error).message;
      log.error({ err: msg }, 'telegram: getMe failed');
      status.updateConnector('telegram', { state: 'error', error: msg });
      return;
    }

    bot = newBot;
    void newBot.start({
      drop_pending_updates: true,
      onStart: () => {
        log.info({ identity }, 'telegram: long polling started');
        status.updateConnector('telegram', {
          state: ownerId ? 'connected' : 'connecting',
          identity,
          detail: ownerId ? null : 'awaiting first message from owner',
          error: null,
        });
      },
    });
  }

  async function stop(): Promise<void> {
    const current = bot;
    bot = null;
    if (current) {
      try {
        await current.stop();
      } catch (err) {
        log.warn({ err: (err as Error).message }, 'telegram: stop error');
      }
    }
    status.updateConnector('telegram', { state: 'disconnected', detail: 'stopped' });
  }

  async function pair(botToken: string): Promise<void> {
    const probe = new Bot(botToken);
    try {
      const me = await probe.api.getMe();
      identity = me.username ? `@${me.username}` : me.first_name;
    } catch (err) {
      const msg = (err as Error).message;
      log.error({ err: msg }, 'telegram: pair getMe failed');
      status.updateConnector('telegram', { state: 'error', error: msg });
      throw err;
    }

    await setToken(KEYCHAIN_BOT_TOKEN, botToken);
    status.updateConnector('telegram', {
      state: 'connecting',
      identity,
      detail: 'awaiting first /start',
      error: null,
    });
    await stop();
    await start();
  }

  async function reset(): Promise<void> {
    await stop();
    try {
      await deleteToken(KEYCHAIN_BOT_TOKEN);
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'telegram: delete bot token failed');
    }
    try {
      await deleteToken(KEYCHAIN_OWNER_ID);
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'telegram: delete owner id failed');
    }
    ownerId = null;
    identity = null;
    status.updateConnector('telegram', {
      state: 'disconnected',
      detail: 'reset',
      identity: null,
      error: null,
    });
  }

  async function sendToOwner(text: string): Promise<void> {
    if (!bot) throw new Error('telegram not connected');
    if (!ownerId) throw new Error('telegram owner not known');
    await bot.api.sendMessage(ownerId, text);
  }

  return { start, stop, pair, reset, sendToOwner };
}
