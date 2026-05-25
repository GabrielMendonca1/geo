import { spawn } from 'node:child_process';
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

  const args = [
    '--append-system-prompt', system,
    '--model', process.env.GEO_CLAW_CLAUDE_MODEL ?? 'claude-sonnet-4-6',
    '--effort', process.env.GEO_CLAW_CLAUDE_EFFORT ?? 'high',
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
