import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build as buildSystemPrompt } from './llm/prompt.js';
import { paths } from './config.js';

function main(): void {
  const system = buildSystemPrompt({
    channelId: 'cli',
    channelKind: 'cli',
    fromName: 'Gabriel',
  });

  const mcpConfig = JSON.stringify({
    mcpServers: {
      geo: { command: paths.geoMcpBridge },
      claw: { command: 'node', args: [paths.clawMcpBridge] },
    },
  });

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
