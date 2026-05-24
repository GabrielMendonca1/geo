import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

const GEO = process.env.GEO_MCP_BRIDGE_PATH ?? "/Users/biel/ARC/Forge/Geo/geo-mcp-bridge/geo-mcp-bridge";
const CLAW = process.env.GEO_CLAW_MCP_BRIDGE_PATH ?? "/Users/biel/ARC/Forge/Geo/geo-claw/dist/claw/mcpBridge.js";

class Client {
  constructor(label, cmd, args) {
    this.label = label;
    this.proc = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    this.buf = "";
    this.id = 1;
    this.pending = new Map();
    this.proc.stdout.setEncoding("utf8");
    this.proc.stdout.on("data", (c) => {
      this.buf += c;
      let i;
      while ((i = this.buf.indexOf("\n")) >= 0) {
        const line = this.buf.slice(0, i).trim();
        this.buf = this.buf.slice(i + 1);
        if (!line) continue;
        try {
          const m = JSON.parse(line);
          if (typeof m.id === "number" && this.pending.has(m.id)) {
            const p = this.pending.get(m.id);
            this.pending.delete(m.id);
            if (m.error) p.reject(new Error(m.error.message));
            else p.resolve(m.result);
          }
        } catch (e) {
          console.error(`[${this.label}] bad json:`, line.slice(0, 200));
        }
      }
    });
    this.proc.stderr.setEncoding("utf8");
    this.proc.stderr.on("data", (c) => process.stderr.write(`[${this.label}:err] ${c}`));
  }
  req(method, params) {
    const id = this.id++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(`timeout ${method}`)); } }, 10000);
      this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }
  notify(method, params) {
    this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }
  kill() { this.proc.kill("SIGTERM"); }
}

async function probe(label, cmd, args) {
  if (!existsSync(args.length ? args[0] : cmd)) {
    console.log(`[${label}] MISSING: ${args.length ? args[0] : cmd}`);
    return;
  }
  const c = new Client(label, cmd, args);
  try {
    await c.req("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "verify", version: "0.1.0" } });
    c.notify("notifications/initialized");
    const r = await c.req("tools/list");
    console.log(`[${label}] ${r.tools.length} tools:`);
    for (const t of r.tools) console.log(`  - ${t.name}`);
  } catch (e) {
    console.log(`[${label}] FAILED: ${e.message}`);
  } finally {
    c.kill();
  }
}

await probe("geo", GEO, []);
await probe("claw", process.execPath, [CLAW]);
process.exit(0);
