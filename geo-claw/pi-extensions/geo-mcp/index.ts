import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type, type TSchema } from "typebox";

type JsonRpcRequest = { jsonrpc: "2.0"; id: number; method: string; params?: unknown };
type JsonRpcResponse = { jsonrpc: "2.0"; id: number; result?: any; error?: { code: number; message: string; data?: unknown } };
type JsonRpcNotification = { jsonrpc: "2.0"; method: string; params?: unknown };

type McpTool = { name: string; description?: string; inputSchema?: any };
type McpContent = { type: string; text?: string; data?: string; mimeType?: string; [k: string]: unknown };
type McpCallResult = { content?: McpContent[]; isError?: boolean };

const REQUEST_TIMEOUT_MS = 30_000;
const GEO_BRIDGE_PATH = process.env.GEO_MCP_BRIDGE_PATH ?? "/Users/biel/ARC/Forge/Geo/geo-mcp-bridge/geo-mcp-bridge";
const CLAW_BRIDGE_PATH = process.env.GEO_CLAW_MCP_BRIDGE_PATH ?? "/Users/biel/ARC/Forge/Geo/geo-claw/dist/claw/mcpBridge.js";

class McpClient {
  private proc: ChildProcessWithoutNullStreams;
  private buffer = "";
  private nextId = 1;
  private pending = new Map<number, { resolve: (r: any) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private dead = false;
  private deathReason?: string;

  constructor(public readonly label: string, command: string, args: string[]) {
    this.proc = spawn(command, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.proc.stdout.setEncoding("utf8");
    this.proc.stdout.on("data", (chunk: string) => this.onStdout(chunk));
    this.proc.stderr.setEncoding("utf8");
    this.proc.stderr.on("data", (chunk: string) => {
      console.error(`[geo-mcp:${this.label}:stderr] ${chunk.trimEnd()}`);
    });
    this.proc.on("exit", (code, signal) => {
      this.dead = true;
      this.deathReason = `exit code=${code} signal=${signal}`;
      for (const [, p] of this.pending) {
        clearTimeout(p.timer);
        p.reject(new Error(`bridge ${this.label} exited: ${this.deathReason}`));
      }
      this.pending.clear();
      console.error(`[geo-mcp:${this.label}] bridge exited (${this.deathReason})`);
    });
    this.proc.on("error", (err) => {
      this.dead = true;
      this.deathReason = err.message;
      console.error(`[geo-mcp:${this.label}] spawn error: ${err.message}`);
    });
  }

  private onStdout(chunk: string) {
    this.buffer += chunk;
    let idx: number;
    while ((idx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, idx).trim();
      this.buffer = this.buffer.slice(idx + 1);
      if (!line) continue;
      let msg: JsonRpcResponse | JsonRpcNotification;
      try {
        msg = JSON.parse(line);
      } catch (e) {
        console.error(`[geo-mcp:${this.label}] bad json: ${line.slice(0, 200)}`);
        continue;
      }
      if ("id" in msg && typeof (msg as JsonRpcResponse).id === "number") {
        const resp = msg as JsonRpcResponse;
        const p = this.pending.get(resp.id);
        if (!p) continue;
        this.pending.delete(resp.id);
        clearTimeout(p.timer);
        if (resp.error) p.reject(new Error(`MCP error ${resp.error.code}: ${resp.error.message}`));
        else p.resolve(resp.result);
      }
    }
  }

  private write(obj: JsonRpcRequest | JsonRpcNotification) {
    this.proc.stdin.write(JSON.stringify(obj) + "\n");
  }

  request<T = any>(method: string, params?: unknown, timeoutMs = REQUEST_TIMEOUT_MS): Promise<T> {
    if (this.dead) return Promise.reject(new Error(`bridge ${this.label} not running (${this.deathReason ?? "unknown"})`));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP request timeout: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params?: unknown) {
    if (this.dead) return;
    this.write({ jsonrpc: "2.0", method, params });
  }

  async handshake(): Promise<void> {
    await this.request("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "geo-mcp-pi-extension", version: "0.1.0" },
    });
    this.notify("notifications/initialized");
  }

  async listTools(): Promise<McpTool[]> {
    const r = await this.request<{ tools: McpTool[] }>("tools/list");
    return r.tools ?? [];
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<McpCallResult> {
    return this.request<McpCallResult>("tools/call", { name, arguments: args });
  }

  shutdown() {
    if (this.dead) return;
    try { this.proc.kill("SIGTERM"); } catch {}
    setTimeout(() => { try { if (!this.proc.killed) this.proc.kill("SIGKILL"); } catch {} }, 2000).unref();
  }
}

function toParamSchema(inputSchema: unknown): TSchema {
  if (inputSchema && typeof inputSchema === "object") return Type.Unsafe(inputSchema as Record<string, unknown>);
  return Type.Object({});
}

function toToolContent(result: McpCallResult): { type: "text"; text: string }[] {
  const out: { type: "text"; text: string }[] = [];
  for (const c of result.content ?? []) {
    if (c.type === "text" && typeof c.text === "string") out.push({ type: "text", text: c.text });
    else if (c.type === "image" && typeof c.data === "string") out.push({ type: "text", text: `[image ${c.mimeType ?? "?"} ${c.data.length} bytes base64]` });
    else out.push({ type: "text", text: JSON.stringify(c) });
  }
  if (out.length === 0) out.push({ type: "text", text: "" });
  return out;
}

async function startBridge(label: string, command: string, args: string[]): Promise<{ client: McpClient; tools: McpTool[] } | null> {
  if (!existsSync(command)) {
    console.error(`[geo-mcp:${label}] binary not found at ${command}; skipping`);
    return null;
  }
  const client = new McpClient(label, command, args);
  try {
    await client.handshake();
    const tools = await client.listTools();
    console.error(`[geo-mcp:${label}] connected, ${tools.length} tools`);
    return { client, tools };
  } catch (e) {
    console.error(`[geo-mcp:${label}] handshake failed: ${(e as Error).message}`);
    client.shutdown();
    return null;
  }
}

export default async function (pi: ExtensionAPI) {
  const clients: McpClient[] = [];

  const bridges: Array<{ prefix: string; label: string; command: string; args: string[] }> = [
    { prefix: "mcp_geo_", label: "geo", command: GEO_BRIDGE_PATH, args: [] },
    { prefix: "mcp_claw_", label: "claw", command: process.execPath, args: [CLAW_BRIDGE_PATH] },
  ];

  for (const b of bridges) {
    const probePath = b.label === "claw" ? CLAW_BRIDGE_PATH : b.command;
    if (!existsSync(probePath)) {
      console.error(`[geo-mcp:${b.label}] script/binary not found at ${probePath}; skipping`);
      continue;
    }
    const started = await startBridge(b.label, b.command, b.args);
    if (!started) continue;
    clients.push(started.client);
    for (const tool of started.tools) {
      const piName = b.prefix + tool.name;
      const originalName = tool.name;
      const client = started.client;
      pi.registerTool({
        name: piName,
        label: piName,
        description: tool.description ?? `${b.label} MCP tool: ${originalName}`,
        parameters: toParamSchema(tool.inputSchema),
        async execute(_toolCallId, params) {
          const result = await client.callTool(originalName, (params ?? {}) as Record<string, unknown>);
          const content = toToolContent(result);
          if (result.isError) {
            const msg = content.map((c) => c.text).join("\n") || "MCP tool reported error";
            throw new Error(msg);
          }
          return { content, details: result };
        },
      });
    }
  }

  pi.on("session_shutdown", async () => {
    for (const c of clients) c.shutdown();
  });
}
