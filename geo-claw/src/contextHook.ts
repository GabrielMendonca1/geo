#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { paths } from './config.js';

const TIMEOUT_MS = 12_000;
const MAX_PROMPT_CHARS = 1000;

const PLANNING_SYSTEM = `Você é o "context retriever" da TUI Geo do Gabriel.

Dado o prompt que o Gabriel está prestes a enviar, busque o contexto mais relevante via MCP tools antes do agente principal responder.

Tools disponíveis:
- geo MCP (mcp__geo__*): blocks (notas markdown), tasks, days (calendário), tags
- claw MCP (mcp__claw__*): conversations_list_channels + conversations_get_history — mensagens externas (WhatsApp/Gmail/Telegram) que o daemon recebeu e respondeu

Estratégia (no máximo 3-4 tool calls):
- Pergunta sobre "hoje" / "meu dia": chame mcp__geo__get_today + mcp__geo__list_tasks
- Tópico específico: mcp__geo__search_blocks com a keyword
- "quem me mandou X" / "WhatsApp" / "email": mcp__claw__conversations_list_channels + opcionalmente get_history
- "o que escrevi sobre Y": mcp__geo__search_blocks com Y

Saída: markdown conciso com fatos, IDs, snippets. Sem responder o prompt em si — você é só o retriever.

Se nada for relevante: responda exatamente "(none)".`;

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks).toString('utf8');
}

async function main(): Promise<void> {
  const raw = await readStdin();
  let input: { prompt?: string };
  try {
    input = JSON.parse(raw);
  } catch {
    return;
  }

  const prompt = (input.prompt ?? '').trim().slice(0, MAX_PROMPT_CHARS);
  if (!prompt) return;

  const mcpConfig = JSON.stringify({
    mcpServers: {
      geo: { command: paths.geoMcpBridge },
      claw: { command: 'node', args: [paths.clawMcpBridge] },
    },
  });

  const result = spawnSync(
    'claude',
    [
      '-p', `Prompt do user: """${prompt}"""\n\nGather relevant Geo context now. Be concise.`,
      '--system-prompt', PLANNING_SYSTEM,
      '--output-format', 'json',
      '--model', 'claude-sonnet-4-6',
      '--effort', 'low',
      '--max-turns', '4',
      '--bare',
      '--strict-mcp-config',
      '--mcp-config', mcpConfig,
    ],
    {
      encoding: 'utf8',
      timeout: TIMEOUT_MS,
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );

  if (result.status !== 0 || !result.stdout) return;

  let parsed: { result?: string };
  try {
    parsed = JSON.parse(result.stdout);
  } catch {
    return;
  }

  const text = (parsed.result ?? '').trim();
  if (!text || text === '(none)') return;

  process.stdout.write(`<geo-context>\n${text}\n</geo-context>\n`);
}

main().catch(() => {});
