import { EventEmitter } from 'node:events';
import type { McpClient, McpNotification } from './client.js';
import { log } from '../log.js';

const SUBSCRIBE_KINDS = ['task', 'block'] as const;

export class GeoSubscription extends EventEmitter {
  constructor(private client: McpClient) {
    super();
    client.on('connected', () => {
      void this.subscribe();
    });
    client.on('notification', (n: McpNotification) => {
      this.handleNotification(n);
    });
  }

  private async subscribe(): Promise<void> {
    try {
      await this.client.call('geo/subscribe', { kinds: SUBSCRIBE_KINDS });
      log.info('geo/subscribe ok');
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'geo/subscribe failed');
    }
  }

  private handleNotification(n: McpNotification): void {
    if (n.method === 'geo/changed') {
      log.debug({ params: n.params }, 'geo/changed');
      this.emit('changed', n.params);
      return;
    }
    this.emit(n.method, n.params);
  }
}
