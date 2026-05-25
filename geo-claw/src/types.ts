export type ConnectorId = 'whatsapp' | 'gmail' | 'telegram';

export type ConnectorState = {
  state: 'disconnected' | 'connecting' | 'qr' | 'authorizing' | 'connected' | 'error';
  detail?: string | null;
  identity?: string | null;
  lastEventAt?: string | null;
  error?: string | null;
};

export type ProviderId = 'claude' | 'codex';

export type CronStatus = {
  id: string;
  title: string;
  cron: string;
  lastRun: string | null;
  lastStatus: 'ok' | 'error' | 'never';
  error: string | null;
  sinks: ('telegram' | 'whatsapp' | 'notification')[];
};

export type StatusFile = {
  version: 2;
  updatedAt: string;
  provider: ProviderId;
  mcp: { connected: boolean; lastTickAt: string | null; error: string | null };
  connectors: {
    whatsapp: ConnectorState;
    gmail: ConnectorState;
    telegram: ConnectorState;
  };
  crons: CronStatus[];
};

export type ChannelKind = ConnectorId | 'cli' | 'nano';

export type ChannelContext = {
  channelId: string;
  channelKind: ChannelKind;
  fromName?: string;
  fromAddress?: string;
  metadata?: {
    subject?: string;
    messageId?: string;
    references?: string;
    inReplyTo?: string;
  };
};

export type LLMTurn = { reply: string | null };

export type RunTurnEvent =
  | { type: 'text'; delta: string }
  | { type: 'tool_use'; toolUseId: string; name: string; input: unknown }
  | { type: 'tool_result'; toolUseId: string; content: unknown; isError?: boolean };

export type RunTurnOpts = {
  onChunk?: (delta: string) => void;
  onEvent?: (event: RunTurnEvent) => void;
};

export interface LLMLoop {
  runTurn(ctx: ChannelContext, userText: string, opts?: RunTurnOpts): Promise<LLMTurn>;
}

export interface StatusWriter {
  updateMcp(patch: Partial<StatusFile['mcp']>): void;
  updateConnector(id: ConnectorId, patch: Partial<ConnectorState>): void;
  setProvider(provider: ProviderId): void;
  setCrons(crons: CronStatus[]): void;
  upsertCron(cron: CronStatus): void;
  removeCron(id: string): void;
  snapshot(): StatusFile;
  flush(): void;
}
