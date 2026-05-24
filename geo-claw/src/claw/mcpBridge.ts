#!/usr/bin/env node
import { ipcCall } from './ipc.js';

type JsonRpcReq = { jsonrpc?: string; id?: unknown; method?: string; params?: unknown };

type Tool = {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  ipcMethod: string;
};

const TOOLS: Tool[] = [
  {
    name: 'whatsapp_send_to_self',
    description:
      "Send a WhatsApp text message from Gabriel's account to his own number (self-DM). Use this to push a quick note, reminder, or status update to his phone.",
    inputSchema: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'Plain text message body. Keep it short.' },
      },
      required: ['text'],
      additionalProperties: false,
    },
    ipcMethod: 'whatsapp.send_to_self',
  },
];

function write(msg: unknown): void {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id: unknown, result: unknown): void {
  write({ jsonrpc: '2.0', id, result });
}

function replyError(id: unknown, code: number, message: string): void {
  write({ jsonrpc: '2.0', id, error: { code, message } });
}

async function handle(req: JsonRpcReq): Promise<void> {
  const { id, method } = req;
  if (method === 'initialize') {
    reply(id, {
      protocolVersion: '2025-11-25',
      capabilities: { tools: {} },
      serverInfo: { name: 'geo-claw', version: '0.1.0' },
    });
    return;
  }
  if (method === 'notifications/initialized' || method?.startsWith('notifications/')) {
    return;
  }
  if (method === 'tools/list') {
    reply(id, {
      tools: TOOLS.map((t) => ({
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
      })),
    });
    return;
  }
  if (method === 'tools/call') {
    const params = (req.params ?? {}) as { name?: string; arguments?: unknown };
    const tool = TOOLS.find((t) => t.name === params.name);
    if (!tool) {
      replyError(id, -32602, `unknown tool: ${params.name}`);
      return;
    }
    try {
      const result = await ipcCall(tool.ipcMethod, params.arguments ?? {});
      reply(id, {
        content: [{ type: 'text', text: JSON.stringify(result) }],
      });
    } catch (err) {
      reply(id, {
        content: [{ type: 'text', text: `error: ${(err as Error).message}` }],
        isError: true,
      });
    }
    return;
  }
  if (id !== undefined) {
    replyError(id, -32601, `method not found: ${method}`);
  }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let nl: number;
  while ((nl = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    let req: JsonRpcReq;
    try {
      req = JSON.parse(line);
    } catch {
      continue;
    }
    void handle(req);
  }
});
process.stdin.on('end', () => process.exit(0));
