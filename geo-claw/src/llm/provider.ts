import { log } from '../log.js';
import type { ChannelContext, LLMLoop, LLMTurn, ProviderId, RunTurnOpts } from '../types.js';
import type { McpClient } from '../mcp/client.js';
import type { McpToolRegistry } from '../mcp/tools.js';
import { build as buildSystemPrompt } from './prompt.js';
import { claudeRunTurn } from './claude.js';
import { codexRunTurn } from './codex.js';

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

function channelDefaults(ctx: ChannelContext): { model?: string; effort?: string; maxTurns?: number } {
  if (ctx.channelKind === 'cli' || ctx.channelKind === 'nano') {
    return {
      model: process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-sonnet-4-6',
      effort: process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'high',
      maxTurns: 8,
    };
  }
  return {};
}

export function createLLMLoop(_deps: LLMLoopDeps): LLMLoop {
  void _deps;

  async function runTurn(ctx: ChannelContext, userText: string, opts?: RunTurnOpts): Promise<LLMTurn> {
    const system = buildSystemPrompt(ctx);
    const provider = resolveProvider();
    try {
      const defaults = channelDefaults(ctx);
      const result =
        provider === 'codex'
          ? await codexRunTurn({ system, userMessage: userText })
          : await claudeRunTurn({
              system,
              userMessage: userText,
              sessionKey: sessionKeyFor(ctx),
              onChunk: opts?.onChunk,
              onEvent: opts?.onEvent,
              model: defaults.model,
              effort: defaults.effort,
              maxTurns: defaults.maxTurns,
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
