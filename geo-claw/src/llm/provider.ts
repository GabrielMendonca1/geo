import { log } from '../log.js';
import type { ChannelContext, LLMLoop, LLMTurn, ProviderId, RunTurnOpts } from '../types.js';
import type { McpClient } from '../mcp/client.js';
import type { McpToolRegistry } from '../mcp/tools.js';
import { SYSTEM_PROMPT, channelContextBlock } from './systemPrompt.js';
import { claudeRunTurn } from './claude.js';
import { codexRunTurn } from './codex.js';
import { formatMemoryContext, loadSnapshot, loadSoul, MEMORY_FENCE_PREAMBLE } from './memory.js';
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

// Channels that get Hermes-style hydration (soul + memory + recent history).
// Nano joins now that its IPC handler writes user msg AFTER runTurn.
// CLI excluded (dev REPL, system prompt already carries everything for one-shot).
const HYDRATED_KINDS = new Set<ChannelContext['channelKind']>(['telegram', 'whatsapp', 'gmail', 'nano']);

// Provider owns persistence for these channels; nano's IPC handler owns its own writes
// (with attachment metadata that provider doesn't see).
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

export function createLLMLoop(deps: LLMLoopDeps): LLMLoop {
  // Hermes-mirror context hydration — runs every turn for HYDRATED_KINDS
  // A. N: history=20 (cap), memory entries≤50 (char-capped), recall≤10 (LIMIT)
  // B. Shape: idx_conv_channel_ts for history, FTS5 for recall, process-cache for snapshot
  // C. Bottleneck: Anthropic API (~1-5s). Local I/O is noise.
  // D. Cache: snapshot cached in memory.ts, invalidated on local memory writes
  // Cold and warm CLI uniform: snapshot rides in userMessage preamble, never system prompt
  async function buildPreamble(ctx: ChannelContext): Promise<string> {
    if (!HYDRATED_KINDS.has(ctx.channelKind)) return '';
    const storageId = storageChannelId(ctx);
    const [soul, snap, history] = await Promise.all([
      loadSoul(deps.mcpClient),
      loadSnapshot(deps.mcpClient),
      Promise.resolve(loadAndFormatHistory(storageId, 20)),
    ]);
    const memBlock = formatMemoryContext(snap);
    const channelBlock = channelContextBlock(ctx);
    const blocks: string[] = [];
    if (soul.length > 0) blocks.push(`<soul>\n${soul.trim()}\n</soul>`);
    if (memBlock.length > 0) blocks.push(memBlock);
    if (history.length > 0) blocks.push(history);
    blocks.push(channelBlock);
    return `${MEMORY_FENCE_PREAMBLE}\n\n${blocks.join('\n\n')}`;
  }

  async function runTurn(ctx: ChannelContext, userText: string, opts?: RunTurnOpts): Promise<LLMTurn> {
    const system = buildSystemPrompt(ctx);
    const provider = resolveProvider();
    const useWarm = ctx.channelKind === 'nano';
    const storageId = storageChannelId(ctx);

    const preamble = await buildPreamble(ctx);
    const enrichedUser = preamble.length > 0 ? `${preamble}\n\n---\n\n${userText}` : userText;
    // Warm sessions bake the system prompt at spawn time, so dynamic context (now-line)
    // must ride with each user message instead.
    const userMessage = useWarm ? `${nowLine()}\n\n${enrichedUser}` : enrichedUser;

    if (PERSISTED_BY_PROVIDER.has(ctx.channelKind)) {
      try {
        appendMessage(storageId, 'user', JSON.stringify({ text: userText }));
      } catch (err) {
        log.warn({ err: (err as Error).message, storageId }, 'llm:persist-user-failed');
      }
    }

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
      const reply = text.length > 0 ? text : null;
      if (reply && PERSISTED_BY_PROVIDER.has(ctx.channelKind)) {
        try {
          appendMessage(storageId, 'assistant', JSON.stringify({ text: reply }));
        } catch (err) {
          log.warn({ err: (err as Error).message, storageId }, 'llm:persist-assistant-failed');
        }
      }
      return { reply };
    } catch (err) {
      log.error({ err: (err as Error).message, provider }, 'llm:runTurn failed');
      throw err;
    }
  }

  return { runTurn };
}
