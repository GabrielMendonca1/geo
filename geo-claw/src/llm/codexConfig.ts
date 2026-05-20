import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { log } from '../log.js';

const CONFIG_PATH = path.join(os.homedir(), '.codex', 'config.toml');

const MCP_BLOCK = `[mcp_servers.geo]
command = "/Users/biel/ARC/Forge/Geo/geo-mcp-bridge/geo-mcp-bridge"
`;

const DEFAULT_CONFIG = `forced_login_method = "chatgpt"
cli_auth_credentials_store = "file"

${MCP_BLOCK}`;

export function ensureCodexConfig(): void {
  try {
    if (!fs.existsSync(CONFIG_PATH)) {
      fs.mkdirSync(path.dirname(CONFIG_PATH), { recursive: true });
      fs.writeFileSync(CONFIG_PATH, DEFAULT_CONFIG, 'utf8');
      log.info({ path: CONFIG_PATH }, 'codex: wrote default config');
      return;
    }
    const existing = fs.readFileSync(CONFIG_PATH, 'utf8');
    if (existing.includes('[mcp_servers.geo]')) return;
    const sep = existing.endsWith('\n') ? '\n' : '\n\n';
    fs.writeFileSync(CONFIG_PATH, `${existing}${sep}${MCP_BLOCK}`, 'utf8');
    log.info({ path: CONFIG_PATH }, 'codex: appended geo mcp block');
  } catch (err) {
    log.warn({ err: (err as Error).message, path: CONFIG_PATH }, 'codex: ensureCodexConfig failed');
  }
}
