import { log } from '../log.js';
import type { ChannelContext, LLMLoop, LLMTurn, ProviderId } from '../types.js';
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

export function createLLMLoop(_deps: LLMLoopDeps): LLMLoop {
  void _deps;

  async function runTurn(ctx: ChannelContext, userText: string): Promise<LLMTurn> {
    const system = buildSystemPrompt(ctx);
    const provider = resolveProvider();
    try {
      const result =
        provider === 'codex'
          ? await codexRunTurn({ system, userMessage: userText })
          : await claudeRunTurn({ system, userMessage: userText });
      const text = result.text.trim();
      return { reply: text.length > 0 ? text : null };
    } catch (err) {
      log.error({ err: (err as Error).message, provider }, 'llm:runTurn failed');
      throw err;
    }
  }

  return { runTurn };
}
