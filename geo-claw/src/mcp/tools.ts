import type { McpClient } from './client.js';
import { log } from '../log.js';

export type AnthropicTool = {
  name: string;
  description?: string;
  input_schema: Record<string, unknown>;
};

type McpTool = {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
  input_schema?: Record<string, unknown>;
};

type McpToolsListResult = { tools?: McpTool[] } | McpTool[];

function normalizeSchema(schema: Record<string, unknown> | undefined): Record<string, unknown> {
  if (!schema || typeof schema !== 'object') {
    return { type: 'object', properties: {} };
  }
  return schema;
}

export class McpToolRegistry {
  private cache: AnthropicTool[] = [];
  private loaded = false;

  constructor(private client: McpClient) {
    client.on('connected', () => {
      void this.refresh();
    });
    client.on('disconnected', () => {
      this.loaded = false;
      this.cache = [];
    });
  }

  async refresh(): Promise<void> {
    try {
      const result = (await this.client.call('tools/list')) as McpToolsListResult | undefined;
      const list: McpTool[] = Array.isArray(result)
        ? result
        : (result?.tools ?? []);
      this.cache = list.map((t): AnthropicTool => ({
        name: t.name,
        description: t.description,
        input_schema: normalizeSchema(t.inputSchema ?? t.input_schema),
      }));
      this.loaded = true;
      log.info({ count: this.cache.length }, 'mcp tools loaded');
    } catch (err) {
      log.warn({ err: (err as Error).message }, 'mcp tools/list failed');
      this.loaded = false;
      this.cache = [];
    }
  }

  isLoaded(): boolean {
    return this.loaded;
  }

  getAnthropicTools(): AnthropicTool[] {
    return this.cache;
  }

  async executeTool(name: string, input: unknown): Promise<{ content: string; isError: boolean }> {
    try {
      const result = await this.client.call('tools/call', { name, arguments: input ?? {} });
      const content = typeof result === 'string' ? result : JSON.stringify(result);
      return { content, isError: false };
    } catch (err) {
      const msg = (err as Error).message;
      log.warn({ tool: name, err: msg }, 'mcp tool execution failed');
      return { content: JSON.stringify({ error: msg }), isError: true };
    }
  }
}
