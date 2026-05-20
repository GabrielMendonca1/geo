import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const envFile = path.join(os.homedir(), 'Library', 'Application Support', 'GeoClaw', 'env');

try {
  const text = fs.readFileSync(envFile, 'utf8');
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if (value.length >= 2) {
      const first = value[0];
      const last = value[value.length - 1];
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        value = value.slice(1, -1);
      }
    }
    if (!(key in process.env)) {
      process.env[key] = value;
    }
  }
} catch {}
