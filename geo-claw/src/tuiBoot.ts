import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { SYSTEM_PROMPT, readSoulDefaultSync, nowLine } from './llm/systemPrompt.js';
import { paths } from './config.js';
import { buildMcpConfigJson } from './mcp/config.js';

function main(): void {
  // CLI doesn't go through provider.ts:buildPreamble — it spawns claude directly.
  // Bake the soul into --system-prompt at boot so the CLI has the same identity
  // as the daemon. The contextHook handles per-turn data retrieval.
  // Tradeoff: CLI doesn't pick up live edits to the Soul Geo block; restart shell.
  const soul = readSoulDefaultSync();
  const parts = [SYSTEM_PROMPT];
  if (soul.length > 0) parts.push(`<soul>\n${soul.trim()}\n</soul>`);
  parts.push(`<channel>\nChannel: cli\nFrom: Gabriel\n${nowLine()}\n</channel>`);
  const system = parts.join('\n\n');

  const mcpConfig = buildMcpConfigJson();

  const distDir = path.dirname(fileURLToPath(import.meta.url));
  const hookScriptPath = path.join(distDir, 'contextHook.js');
  const settingsPath = path.join(path.dirname(paths.statusFile), 'claude-tui-settings.json');

  const skipHook = process.env.GEO_TUI_NO_HOOK === '1';

  const settings = skipHook
    ? {}
    : {
        hooks: {
          UserPromptSubmit: [
            {
              matcher: '.*',
              hooks: [{ type: 'command', command: `node ${hookScriptPath}` }],
            },
          ],
        },
      };

  mkdirSync(path.dirname(settingsPath), { recursive: true });
  writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf8');

  const args = [
    '--settings', settingsPath,
    '--system-prompt', system,
    '--model', process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-opus-4-7',
    '--effort', process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'xhigh',
    '--strict-mcp-config',
    '--mcp-config', mcpConfig,
  ];

  const child = spawn('claude', args, { stdio: 'inherit' });
  child.on('exit', (code) => process.exit(code ?? 0));
  child.on('error', (err) => {
    process.stderr.write(`failed to launch claude: ${err.message}\n`);
    process.exit(1);
  });
}

main();
