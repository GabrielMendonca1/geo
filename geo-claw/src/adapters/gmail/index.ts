import type { gmail_v1 } from 'googleapis';
import { log } from '../../log.js';
import type { LLMLoop, StatusWriter } from '../../types.js';
import { authorizeInteractive, getAuthorizedClient } from './oauth.js';
import { pollOnce } from './inbound.js';
import { sendReply as sendReplyOutbound } from './outbound.js';

const POLL_INTERVAL_MS = 30_000;

export interface GmailAdapter {
  start(): Promise<void>;
  stop(): Promise<void>;
  authorize(): Promise<void>;
}

export interface GmailAdapterDeps {
  llm: LLMLoop;
  status: StatusWriter;
}

export function createGmailAdapter(deps: GmailAdapterDeps): GmailAdapter {
  const { llm, status } = deps;
  let timer: NodeJS.Timeout | null = null;
  let running = false;
  let gmail: gmail_v1.Gmail | null = null;
  let userEmail: string | null = null;

  const stopTimer = () => {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
  };

  const tick = async () => {
    if (!gmail || !userEmail) return;
    if (running) return;
    running = true;
    try {
      await pollOnce({
        gmail,
        userEmail,
        llm,
        status,
        sendReply: sendReplyOutbound,
      });
    } catch (err) {
      const message = (err as Error).message;
      log.error({ err: message }, 'gmail: poll error');
      status.updateConnector('gmail', { error: message });
    } finally {
      running = false;
    }
  };

  const start = async (): Promise<void> => {
    stopTimer();
    status.updateConnector('gmail', { state: 'connecting', detail: undefined, error: undefined });

    let client: gmail_v1.Gmail | null = null;
    try {
      client = await getAuthorizedClient();
    } catch (err) {
      const message = (err as Error).message;
      log.error({ err: message }, 'gmail: getAuthorizedClient failed');
      status.updateConnector('gmail', { state: 'error', error: message });
      return;
    }

    if (!client) {
      status.updateConnector('gmail', {
        state: 'disconnected',
        detail: 'not authorized — write signals/request-auth-gmail to start OAuth',
      });
      return;
    }

    let email: string;
    try {
      const profile = await client.users.getProfile({ userId: 'me' });
      email = profile.data.emailAddress ?? '';
      if (!email) throw new Error('profile missing emailAddress');
    } catch (err) {
      const message = (err as Error).message;
      log.error({ err: message }, 'gmail: getProfile failed');
      status.updateConnector('gmail', { state: 'error', error: message });
      return;
    }

    gmail = client;
    userEmail = email;
    status.updateConnector('gmail', {
      state: 'connected',
      identity: email,
      detail: undefined,
      error: undefined,
    });

    void tick();
    timer = setInterval(() => {
      void tick();
    }, POLL_INTERVAL_MS);
  };

  const stop = async (): Promise<void> => {
    stopTimer();
    gmail = null;
    userEmail = null;
    status.updateConnector('gmail', { state: 'disconnected', detail: undefined });
  };

  const authorize = async (): Promise<void> => {
    stopTimer();
    status.updateConnector('gmail', { state: 'authorizing', detail: undefined, error: undefined });
    try {
      await authorizeInteractive();
    } catch (err) {
      const message = (err as Error).message;
      log.error({ err: message }, 'gmail: authorize failed');
      status.updateConnector('gmail', { state: 'error', error: message });
      return;
    }
    await start();
  };

  return { start, stop, authorize };
}
