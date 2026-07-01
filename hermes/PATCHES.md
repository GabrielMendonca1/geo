# PATCHES.md — fork patches do agent Geo sobre o hermes upstream

Registro canônico dos patches que o agent Geo aplica **sobre o hermes-agent upstream puro**
(`~/.hermes/hermes-agent`, branch `clean-v0.17.0` @ tag `v2026.6.19`). Reaplicar após cada
`hermes update` / troca de tag. Cada patch é mínimo e adaptado à versão — `git cherry-pick`
NÃO serve (paths/linhas mudam entre releases). Antes desta consolidação (2026-06-20) os patches
viviam só em carried commits e **erodiam silenciosamente** a cada update.

Base atual: **v0.17.0 (2026.6.19)** · upstream `2bd1977d`.

---

## P2 — geo_context → context_prompt (lookup Geo por-turno)  ·  STATUS: ✅ APLICADO

Anexa o snippet do hook `geo-context` (escrito no `agent:start`) ao prompt do turno.
Sem ele, o hook escreve o sidecar em `runtime/geo-context/` mas o snippet não chega ao agente
(a identidade fixa via `MEMORY.md`/`config.yaml memory.path` continua funcionando — é outra via).

- **Arquivo:** `gateway/run.py`, logo após `await self.hooks.emit("agent:start", hook_ctx)`
- **Patch:** `patches/P2-geo-context-append.patch` (`git apply` na raiz do hermes-agent)
- **Mecanismo:** `emit` passa `hook_ctx` por referência; o handler in-process faz
  `context["geo_context"] = body` (handler.py:646) → visível após o emit.
- **Verificar:** mandar 1 msg no Telegram e confirmar que o turno vê contexto Geo fresco.

## P1a — `_MCP_TOOL_PREFIX = ""` (Opus Max free lane)  ·  STATUS: ⬜ DISPONÍVEL, NÃO APLICADO

Desabilita o prefixo `mcp__` nos tool names no path OAuth. Em token de subscription Max, a Anthropic
roteia tool calls com prefixo `mcp__` ao bucket de extra-usage (vazio) → 400 "out of extra usage";
nomes planos billam na cota incluída. É o que deixa Opus+tools rodar de graça no lane Anthropic.

- **Arquivo:** `agent/anthropic_adapter.py:375` — upstream v0.17.0 = `_MCP_TOOL_PREFIX = "mcp__"` (mudou de `mcp_`)
- **Aplicar:** trocar para `_MCP_TOOL_PREFIX = ""`. Inbound strip em `agent/transports/anthropic.py`
  é guardado por `startswith(_MCP_TOOL_PREFIX)` → com `""` o round-trip fica consistente.
- **RE-VALIDAR antes:** o upstream mudou `mcp_`→`mcp__`; confirmar que a lógica de billing ainda
  vale neste release antes de aplicar. Smoke: tool `ping`→200, `mcp__ping`→comportamento esperado.
- **Por que não aplicado:** já tinha erodido no estado final do fork antigo; lane atual = `openai-codex`
  (`config.yaml providers: {}`). Aplicar só se voltar a usar o lane Anthropic/Opus via Max.

## P1b — header `User-Agent` capital (Claude-Code billing contract)  ·  STATUS: ⬜ DISPONÍVEL, NÃO APLICADO

`build_anthropic_client` usa `"user-agent"` minúsculo → httpx junta com o `"User-Agent"` do SDK
em dois valores → quebra o contrato first-party Claude-Code → billing rejeita como extra-usage.
Patch: usar `"User-Agent"` capital (sobrescreve o default do SDK).

- **Arquivo:** `agent/anthropic_adapter.py` em `build_anthropic_client` (kwargs `default_headers`)
- **Dependência:** anda junto com P1a (mesmo lane Max). RE-VALIDAR contra o código v0.17.0 atual.

## P3 — retry auto-paused platforms (15-min heartbeat)  ·  STATUS: ❌ DROP (obsoleto)

O reconnect nativo do upstream cobre. Validado em 2026-06-20: após falhas de rede o gateway
logou `✓ telegram reconnected successfully` sozinho. O próprio commit antigo `58a65f515` já marcou
"drop obsolete auto-pause retry, take upstream reconnect logic". **Não migrar.**

## P4 — launchd plist hardening  ·  STATUS: ⬜ OPCIONAL (baixa prioridade)

`ThrottleInterval=10` + `SoftResourceLimits NumberOfFiles=4096` em `generate_launchd_plist()`
(`hermes_cli/gateway.py`). O plist ativo em `~/Library/LaunchAgents/` já tem o hardening
materializado; só importa se o plist for regenerado pelo código. Origem: `stash@{0}` do fork antigo.

---

## Reaplicar tudo após update

```
cd ~/.hermes/hermes-agent
git apply ~/Arca/Forge/Geo/hermes/patches/P2-geo-context-append.patch   # P2
# P1a/P1b: só se usar lane Anthropic/Max — re-validar então editar agent/anthropic_adapter.py
~/.local/bin/uv pip install --python ./venv/bin/python -e '.[all]'       # rebuild deps se a tag mudou
~/Arca/Forge/Geo/hermes/install.sh                                       # camada Geo (config/SOUL/hooks/daemons)
launchctl bootout gui/$(id -u)/ai.hermes.gateway; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.hermes.gateway.plist
```
