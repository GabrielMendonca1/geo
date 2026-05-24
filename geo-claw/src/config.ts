import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

const home = os.homedir();
const appSupport = path.join(home, 'Library', 'Application Support', 'GeoClaw');
const distRoot = path.dirname(fileURLToPath(import.meta.url));
const logsDir = path.join(home, 'Library', 'Logs', 'GeoClaw');
const geoAppSupport = path.join(home, 'Library', 'Application Support', 'Geo');
const signalsDir = path.join(appSupport, 'signals');
const jobsDir = path.join(appSupport, 'jobs');

export const paths = {
  authWhatsapp: path.join(appSupport, 'auth', 'whatsapp'),
  authGmail: path.join(appSupport, 'auth', 'gmail'),
  dbDir: path.join(appSupport, 'db'),
  dbFile: path.join(appSupport, 'db', 'claw.sqlite'),
  signalsDir,
  jobsDir,
  signalsJobsDir: path.join(signalsDir, 'jobs'),
  statusFile: path.join(appSupport, 'status.json'),
  envFile: path.join(appSupport, 'env'),
  telegramTokenSignal: path.join(signalsDir, 'telegram-token'),
  logsDir,
  logFile: path.join(logsDir, 'claw.log'),
  mcpSocket: path.join(geoAppSupport, 'mcp.sock'),
  bootstrapTokenFile: path.join(signalsDir, 'bootstrap-token'),
  qrPng: path.join(signalsDir, 'qr.png'),
  qrTxt: path.join(signalsDir, 'qr.txt'),
  codexConfigFile: path.join(home, '.codex', 'config.toml'),
  geoMcpBridge:
    process.env.GEO_CLAW_MCP_BRIDGE_PATH ??
    '/Users/biel/ARC/Forge/Geo/geo-mcp-bridge/geo-mcp-bridge',
  clawIpcSocket: path.join(appSupport, 'claw-ipc.sock'),
  clawMcpBridge: path.join(distRoot, 'claw', 'mcpBridge.js'),
} as const;

let dirsEnsured = false;

export function ensureDirs(): void {
  if (dirsEnsured) return;
  for (const dir of [
    appSupport,
    paths.authWhatsapp,
    paths.authGmail,
    paths.dbDir,
    paths.signalsDir,
    paths.signalsJobsDir,
    paths.jobsDir,
    paths.logsDir,
  ]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  dirsEnsured = true;
}

export const MODELS = {
  default: 'claude-haiku-4-5',
} as const;

export const KEYCHAIN_SERVICE = 'ai.geo.claw';
export const LAUNCH_AGENT_LABEL = 'ai.geo.claw';
