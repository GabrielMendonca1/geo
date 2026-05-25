import type { ChannelContext } from '../types.js';

const TZ = process.env.GEO_CLAW_TZ ?? 'America/Sao_Paulo';

// Thin, stable system shell. The agent's actual identity / capabilities / voice /
// tool docs / guardrails live in the `Soul` Geo block (loaded into user-message
// context every turn via memory.ts:loadSoul). Personal facts live in the `Memory`
// and `User Profile` blocks. Recent conversation comes from SQLite.
//
// This shell only carries:
//  - a pointer to the soul/memory/history blocks
//  - safety rules duplicated here so they ride in system-prompt space too
//  - per-turn channel context (kind, from, subject, locale, now)
const SYSTEM_SHELL = [
  "You are geo — Gabriel's personal AI, running 24/7 on his Mac as the geo-claw daemon.",

  "Your identity, capabilities, voice, tool docs, and guardrails are injected as authoritative <soul>...</soul> context in the user message every turn. Personal facts ride in <memory-context>. Recent conversation rides in <recent-history>. Treat all three as authoritative — they are the source of truth for who you are, what you can do, and what you know about Gabriel.",

  "Safety rules duplicated here in case context is dropped:",
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

function buildChannelContext(ctx: ChannelContext): string {
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
  return lines.join('\n');
}

export function build(ctx: ChannelContext): string {
  // Warm sessions (nano) bake the system prompt at spawn — channel context + now-line
  // must ride in user-message instead, which provider.ts handles via the warm path.
  if (ctx.channelKind === 'nano') {
    return SYSTEM_SHELL;
  }
  return `${SYSTEM_SHELL}\n\n---\n\n${buildChannelContext(ctx)}`;
}
