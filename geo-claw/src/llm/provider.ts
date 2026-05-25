import { log } from '../log.js';
import type { ChannelContext, LLMLoop, LLMTurn, ProviderId, RunTurnOpts } from '../types.js';
import type { McpClient } from '../mcp/client.js';
import type { McpToolRegistry } from '../mcp/tools.js';
import { build as buildSystemPrompt, nowLine } from './prompt.js';
import { claudeRunTurn } from './claude.js';
import { codexRunTurn } from './codex.js';
import { formatPreamble, loadSnapshot } from './memory.js';
import { loadAndFormatHistory } from './historyHydrate.js';
import { appendMessage } from '../store/db.js';

export interface LLMLoopDeps {
  mcpClient: McpClient;
  toolRegistry: McpToolRegistry;
}

function resolveProvider(): ProviderId {
  return process.env.GEO_CLAW_PROVIDER === 'codex' ? 'codex' : 'claude';
}

function sessionKeyFor(ctx: ChannelContext): string {
  return `${ctx.channelKind}:${ctx.channelId}`;
}

// Channels that get Hermes-style hydration (memory snapshot + recent history).
const HYDRATED_KINDS = new Set<ChannelContext['channelKind']>(['telegram', 'whatsapp', 'gmail', 'nano']);
// Channels where provider.ts owns persistence. Nano excluded: the IPC handler
// in index.ts already writes nano turns with attachment metadata.
const PERSISTED_BY_PROVIDER = new Set<ChannelContext['channelKind']>(['telegram', 'whatsapp', 'gmail']);

function storageChannelId(ctx: ChannelContext): string {
  return `${ctx.channelKind}:${ctx.channelId}`;
}

function channelDefaults(ctx: ChannelContext): { model?: string; effort?: string; maxTurns?: number } {
  if (ctx.channelKind === 'cli') {
    return {
      model: process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-sonnet-4-6',
      effort: process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'high',
      maxTurns: 8,
    };
  }
  if (ctx.channelKind === 'nano') {
    return {
      model: process.env.GEO_CLAW_NANO_MODEL ?? 'claude-haiku-4-5',
      effort: process.env.GEO_CLAW_NANO_EFFORT ?? 'low',
      maxTurns: 6,
    };
  }
  return {};
}

export function createLLMLoop(_deps: LLMLoopDeps): LLMLoop {
  void _deps;

  async function runTurn(ctx: ChannelContext, userText: string, opts?: RunTurnOpts): Promise<LLMTurn> {
    const system = buildSystemPrompt(ctx);
    const provider = resolveProvider();
    const useWarm = ctx.channelKind === 'nano';
    // Warm sessions bake the system prompt at spawn time, so dynamic context (now-line)
    // must ride with each user message instead.
    const userMessage = useWarm ? `${nowLine()}\n\n${userText}` : userText;
    try {
      const defaults = channelDefaults(ctx);
      const result =
        provider === 'codex'
          ? await codexRunTurn({ system, userMessage })
          : await claudeRunTurn({
              system,
              userMessage,
              sessionKey: sessionKeyFor(ctx),
              onChunk: opts?.onChunk,
              onEvent: opts?.onEvent,
              model: defaults.model,
              effort: defaults.effort,
              maxTurns: defaults.maxTurns,
              warm: useWarm,
              attachments: opts?.attachments,
            });
      const text = result.text.trim();
      return { reply: text.length > 0 ? text : null };
    } catch (err) {
      log.error({ err: (err as Error).message, provider }, 'llm:runTurn failed');
      throw err;
    }
  }

  return { runTurn };
}
