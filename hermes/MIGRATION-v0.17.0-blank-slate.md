# SPEC — Migração do agent Geo para Hermes v0.17.0 (modelo blank-slate)

**Data:** 2026-06-20 · **Autor:** Geo (Claude) · **Status:** EXECUTADA (P2 aplicado, camada Geo validada, PATCHES.md criado)
**Escopo:** instância LOCAL do agent Geo (`~/.hermes`). Arca/`hermes-pure` fora de escopo (ver §7).

> **Resultado (2026-06-20):** base v0.17.0 blank-slate · **P2 reaplicado e ativo** (`patches/P2-geo-context-append.patch`) ·
> **P3 dropado** (reconnect nativo validado: `✓ telegram reconnected successfully`) · camada Geo intacta (hook + plugins
> geo-* + `MEMORY.md` 2766 chars) · **P1a/P1b documentados mas NÃO aplicados** — já tinham erodido no fork final e o lane
> atual é `openai-codex`, não Anthropic. Registro canônico: `PATCHES.md`.

---

## 1. Problema

O "hermes antigo" (agent local do Geo) era um **fork divergente** de upstream:
`GabrielMendonca1/hermes-agent`, branch `biel-code`, **495 commits atrás** de NousResearch,
com working tree sujo e um merge anterior de 1.892 commits. Atualizar = merge caótico.

O blank-slate de código (já feito) trocou a base para a **tag upstream pura `v2026.6.19` (v0.17.0)**,
descartando os 9 carried commits. Isso resolveu a divergência, mas **deixou cair as customizações
que faziam o agent ser "o Geo"** — algumas essenciais. Migrar = reintroduzir essas customizações
**sobre a base limpa, de forma documentada e repetível**, sem recriar o fork.

## 2. Tese — modelo de 2 camadas + patch-set mínimo

Substituir "fork divergente" por:

```
Camada 1 — BASE     : hermes-agent upstream puro, rastreando tags (hoje clean-v0.17.0 @ v2026.6.19)
Camada 2 — GEO      : repo ~/Arca/Forge/Geo/hermes (config.yaml, SOUL.md, hooks/, launch-agents/,
                      status-poller/, whatsapp-ingest/) + hermes-extensions/ (plugins geo-*).
                      Aplicada por install.sh — idempotente, blank-slate-friendly. JÁ PRESERVADA.
Camada 3 — PATCHES  : conjunto MÍNIMO de patches no core do hermes que NÃO têm equivalente
                      plugável/nativo. Documentados em PATCHES.md, aplicáveis sobre qualquer tag.
```

Tudo que cabe em config/plugin/hook fica na Camada 2 (sobrevive a updates sozinho).
Só o irredutível vira Camada 3. Update futuro = `checkout nova tag` → `install.sh` → aplicar patch-set.

## 3. Inventário do que migrar (com evidência)

### 3.1 Camada GEO (já presente — só validar)
Já em `~/.hermes` (não foi tocada). Restaurável a qualquer momento por `install.sh` do repo Geo.
- `config.yaml` → `soul.path`, `plugins.enabled: [geo-tools, geo-search-tool]`, toolsets `geo`/`geo_context`
- `SOUL.md` (23 KB) via symlink → `Arca/Forge/Geo/hermes/SOUL.md`
- `hooks/geo-context/` (handler.py, HOOK.yaml, haiku.py) — **via #1 ATIVA** (reescreve `memories/MEMORY.md`
  no `session:start`, injetado em todo turno por `config.yaml memory.path`). Confirmado no log pós-upgrade.
- plugins `geo-tools`, `geo-search-tool` (de `hermes-extensions/`), `whatsapp-confirm`
- daemons `status-poller/`, `whatsapp-ingest/` (Baileys) + plists em `launch-agents/`
- **Ação:** rodar `install.sh` idempotente sobre a base v0.17.0 e validar schema do `config.yaml`.

### 3.2 Camada PATCHES (core — reaplicação manual adaptada; cherry-pick NÃO serve, paths mudaram)

| # | Patch | Origem (antigo) | Alvo (v0.17.0) | Prioridade | Notas |
|---|-------|-----------------|----------------|------------|-------|
| P1 | `_MCP_TOOL_PREFIX = ""` (Opus Max free lane) | `agent/anthropic_adapter.py` (4 commits) | `agent/anthropic_adapter.py:375` | **ESSENCIAL** | upstream mudou `mcp_`→`mcp__`. RE-VALIDAR billing + inbound strip em `agent/transports/anthropic.py` antes de aplicar |
| P2 | geo_context → context_prompt (via #2, lookup por-turno) | `gateway/run.py` (47ee955b2, 5 linhas) | `hermes_cli/gateway.py` (localizar montagem do context_prompt) | MÉDIA | hook escreve sidecar mas v0.17.0 não tem `hook_ctx`/`additionalContext` nativo (P1-grep vazio). Sem o patch, via #2 fica inerte (via #1 cobre a identidade) |
| P3 | retry auto-paused platforms 15min heartbeat | `gateway/run.py` (9abc33e47, 20 linhas) | — | **DROP (provável)** | o próprio commit 58a65f515 já marcou "drop obsolete auto-pause retry, take upstream reconnect logic". Validar reconnect nativo do v0.17.0 e não migrar |
| P4 | launchd plist hardening (`ThrottleInterval=10`, `NumberOfFiles=4096`) | stash@{0} `generate_launchd_plist()` | `hermes_cli/gateway.py` | BAIXA | plist ativo já tem o hardening materializado; só importa se o plist for regenerado pelo código |

`DEVELOPMENT.md` (untracked no stash) — revisar conteúdo; provável nota de dev, não migra.

### 3.3 Documentação canônica (NOVO — resolve o problema-raiz)
`PATCHES.md` é referenciado pelo comentário do P1 mas **não existe**. Criar em `~/Arca/Forge/Geo/hermes/PATCHES.md`
listando cada patch da Camada 3: o quê, por quê, arquivo:linha, como re-validar pós-update. Sem isso, os
patches voltam a viver só em commits perdíveis → reaparece o fork.

## 4. Plano de execução (fases)

- **F0 — Pré (feito):** blank-slate v0.17.0, estado preservado, backup (`tag backup/pre-v0.17.0-blank-slate`
  @ 58a65f515, branch `biel-code`, `stash@{0}`), gateway religado e verde.
- **F1 — PATCHES.md:** extrair os diffs dos carried commits para `PATCHES.md` versionado no repo Geo.
- **F2 — P1 (essencial):** re-validar a lógica `mcp__` no v0.17.0 (outbound prefix + inbound strip), aplicar
  `_MCP_TOOL_PREFIX = ""`, smoke test do lane Anthropic/Opus (tool call `ping`→200, `mcp__ping`→comportamento).
  *Obs: instância local hoje usa provider `openai-codex`; P1 só morde no lane Anthropic.*
- **F3 — P2 (opcional, sua escolha):** localizar a montagem do `context_prompt` em `hermes_cli/gateway.py`,
  reaplicar as 5 linhas do geo_context append; verificar sidecar `runtime/geo-context/` chegando ao prompt.
- **F4 — P4 (opcional):** reaplicar hardening em `generate_launchd_plist()` se quiser plist regenerável limpo.
- **F5 — Camada Geo:** rodar `install.sh`, validar `config.yaml` no schema v0.17.0, restart launchd.
- **F6 — Verificação:** §5.

Cada patch da Camada 3 fica numa branch/patch-file aplicável sobre a tag, não em commits soltos na `biel-code`.

## 5. Critérios de sucesso

- `hermes --version` → v0.17.0, **sem** "carried commits". ✅ (já)
- gateway up, Telegram + WhatsApp connected, 3 crons. ✅ (já)
- Identidade Geo injetando (`MEMORY.md` reescrito no session:start). ✅ (já)
- P1: lane Anthropic/Opus faz tool calls sem 400 "out of extra usage" (se/quando usar o lane).
- P2 (se escolhido): snippet por-turno do geo-context presente no prompt do agente.
- `PATCHES.md` existe e descreve o patch-set; reproduzível em update futuro.

## 6. Riscos / rollback

- **P1 mal reaplicado** → billing 400 OU tools quebradas no lane Anthropic. Mitiga: re-validar antes, smoke test.
- **config.yaml schema drift** (v0.16→v0.17) → gateway crash-loop. Mitiga: `install.sh` faz backup; migração
  já rodou limpa uma vez (F0). Rollback total: `git checkout biel-code` + reinstalar deps + restaurar stash.
- **Rollback de base:** `git checkout backup/pre-v0.17.0-blank-slate` no repo do hermes-agent → volta ao v0.16.0 fork.

## 7. Fora de escopo

- **Arca / `hermes-pure`** (`/opt/arca-projects/gabriel/hermes-pure`): atualizado a v0.17.0 antes do "não encoste";
  decisão pendente (reverter p/ v2026.6.5 ou manter). É 1-container upstream puro (sem camada Geo local) →
  se mantido em v0.17.0, não precisa desta migração; alinhar config separadamente se desejado.
