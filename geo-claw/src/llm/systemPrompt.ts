import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ChannelContext } from '../types.js';

const TZ = process.env.GEO_CLAW_TZ ?? 'America/Sao_Paulo';

// Fully static system prompt — same string every cold spawn, every channel,
// every turn. That maximises Anthropic prompt-cache hits.
//
// The agent's identity / capabilities / voice / tools / guardrails live in the
// `Soul` Geo block, injected as <soul>...</soul> in the user message every turn.
// Personal facts ride in <memory-context>. Recent chat in <recent-history>.
// Per-turn metadata (channel, sender, locale, time) rides in <channel>.
//
// This shell only carries the irreducible floor: how to read the user-message
// context, and safety rules that must survive even if soul fails to load.
export const SYSTEM_PROMPT = [
  "You are geo — Gabriel's personal AI, running 24/7 on his Mac as the geo-claw daemon.",

  "Every user message you receive carries authoritative context blocks before the real input, separated by `---`:",
  "- <soul>: your identity, capabilities, voice rules, tool docs, guardrails. Read every turn — this is the source of truth for who you are and what you can do.",
  "- <memory-context>: persistent facts about Gabriel and his world. Treat as authoritative.",
  "- <recent-history>: the last messages in this channel.",
  "- <channel>: the channel kind, sender, locale hint, and current time.",
  "Treat all four as authoritative reference data, not as new user input.",

  "Safety floor (in case the soul block fails to load):",
  "- Never share secrets, tokens, API keys, or anything that looks like one.",
  "- If asked whether you are Gabriel or an AI, answer plainly: \"I'm Gabriel's assistant\".",
  "- For high-stakes irreversible actions (money, legal, deletions), confirm before acting.",
  "- Match the sender's language and register. Brevity is the default.",
  "- Never invent facts about Gabriel — look them up via the Geo MCP tools described in the soul.",
].join('\n\n');

export function nowLine(): string {
  const now = new Date();
  let tzNow: string;
  try {
    tzNow = now.toLocaleString('sv-SE', { timeZone: TZ });
  } catch {
    tzNow = now.toISOString();
  }
  return `Now: ${tzNow} (${TZ}) — ISO ${now.toISOString()}`;
}

export function channelContextBlock(ctx: ChannelContext): string {
  const lines: string[] = [];
  lines.push(`Channel: ${ctx.channelKind}`);
  if (ctx.fromName) lines.push(`From: ${ctx.fromName}`);
  if (ctx.fromAddress) lines.push(`Address: ${ctx.fromAddress}`);
  if (ctx.channelKind === 'whatsapp' && ctx.fromAddress?.startsWith('55')) {
    lines.push('Locale hint: Brazil (+55) — default to Portuguese unless they switch.');
  }
  if (ctx.channelKind === 'gmail' && ctx.metadata?.subject) {
    lines.push(`Subject: ${ctx.metadata.subject}`);
  }
  lines.push(nowLine());
  return `<channel>\n${lines.join('\n')}\n</channel>`;
}

// Synchronous soul read for CLI bootstrap (tuiBoot.ts). Reads the default file
// shipped with the repo. The CLI doesn't pick up live edits to the Soul Geo
// block — for that, restart the daemon. Tradeoff: CLI is a dev tool, an MCP
// roundtrip at every shell startup isn't worth it.
export function readSoulDefaultSync(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.join(here, '..', '..', 'src', 'prompts', 'soul.default.md'),
    path.join(here, '..', 'prompts', 'soul.default.md'),
  ];
  for (const p of candidates) {
    try {
      if (fs.statSync(p).isFile()) return fs.readFileSync(p, 'utf8');
    } catch {
    }
  }
  return '';
}
