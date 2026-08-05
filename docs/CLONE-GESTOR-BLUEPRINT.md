# Blueprint — Clone do geo para o Gestor (agente pessoal + financeiro)

> Fonte da verdade para **produtizar o geo** como agente pessoal de um *gestor*.
> Deriva do hermes(geo) do Gabriel; mantém a arquitetura verbatim, reseta a identidade/dados e
> **adiciona um módulo financeiro** (contas bancárias + agregação) que o geo stock não tem.
>
> Referências vivas do molde: `~/ARCA/Forge/Geo/CLAUDE.md`, `~/ARCA/Forge/Geo/hermes/PATCHES.md`,
> `~/ARCA/Forge/Geo/hermes/install.sh`, `~/ARCA/Forge/Geo/hermes/SOUL.md`.

---

## 0. O que estamos construindo

Um clone **quase-exato** do geo para um **novo dono (um gestor)**, com 3 adaptações-alvo:

1. **Vault existente + Obsidian como visualizador.** O gestor já tem um vault; o Obsidian abre o vault direto (é Markdown puro). Reusamos o vault dele como `Vault`.
2. **WhatsApp READ-ONLY** para extrair **tarefas** e **sinais financeiros** (PIX, boletos, valores, cobranças). O daemon de ingest do geo **já é read-only por construção** — nenhum envio.
3. **Módulo financeiro (NOVO):** rastreio de contas bancárias + financeiro geral, agregado num **sistema único** (o vault) consultável tanto pelo agente (hermes) quanto pelo Obsidian.

| Camada | O que é | Ação no clone |
|---|---|---|
| **L0 — Hermes upstream** | `hermes-agent` vendorizado, **v0.18.0**, tag `v2026.7.1` (`76a468e5`) | **COPIAR verbatim** (pinado) |
| **L1 — Camada Geo** | `install.sh`: `config.yaml`, hooks (`geo_context` P2), daemons (`whatsapp-ingest`, `status-poller`, `geo-indexer`), plugins (`geo-tools` 31 tools), plists | **COPIAR** e re-parametrizar |
| **L2 — Runtime + identidade/máquina** | `SOUL.md`, `memories/`, `.env`, `Vault/`, keychain, auth WhatsApp, ids Telegram, IP Tailscale, paths absolutos | **RESETAR / RE-APONTAR** |
| **L+ — Financeiro** | contas, lançamentos, agregação, ingest bancário | **CONSTRUIR (novo)** |

---

## 1. Arquitetura em 3 camadas — mapa keep/reset

### L0 — Hermes upstream (copiar verbatim, pinado)
- Base: `hermes-agent` da NousResearch, **v0.18.0**, HEAD `65a610b0` = tag `v2026.7.1` (`76a468e5`) **+ patch P2 reaplicado** (ver PATCHES.md).
- Instala em `~/.hermes/hermes-agent/`, `uv pip install -e '.[all]'`, venv em `venv/` (o plist usa `venv/bin/python`).
- **Não** atualizar às cegas (upstream está `behind: 263`); pinar na tag e reaplicar P2 é a política do fork.

### L1 — Camada Geo (copiar, depois re-parametrizar)
Aplicada por `~/ARCA/Forge/Geo/hermes/install.sh` sobre `HERMES_HOME` (`DEST_DIR=${HERMES_HOME:-$HOME/.hermes}`), idempotente:
- `config.yaml` → copy-with-backup.
- `SOUL.md` → **symlink** para a fonte no repo.
- `memories/{MEMORY.md,USER.md}` → copy-with-backup.
- `.env` → **copy_if_absent** (preserva o existente).
- rsync **sem `--delete`** de `status-poller/`, `whatsapp-ingest/`, `hooks/`, `scripts/` (preserva auth/state).
- `bin/` → rsync. `launch-agents/*.plist` → `~/Library/LaunchAgents/`.
- Patch **P2** (`geo_context → context_prompt`, `git apply patches/P2-geo-context-append.patch` em `gateway/run.py`) — **obrigatório**.
- Plugins Geo em `~/.hermes/plugins/`: `geo-tools` (31 tools `geo_*`), `geo-search-tool`, `whatsapp-confirm` (fonte em `hermes-extensions/`).

### L2 — Resetar / re-apontar (checklist canônico, §6)
Tudo que é do Gabriel: identidade, segredos, vault, canais, máquina.

---

## 2. Pré-requisitos da máquina do gestor

- macOS + Homebrew; **Node** em `/opt/homebrew/bin/node` (Baileys/ingest).
- Python + **`uv`** (o venv do hermes usa `uv pip`).
- **Obsidian** instalado, com o vault do gestor identificado (path).
- **Lane de chat LLM** decidida (ver §Decisões): o geo usa `model: gpt-5.5 / provider: openai-codex`. O clone precisa de uma lane própria (chave/subscrição do gestor).
- Opcional: **CuaDriver.app** (computer-use), **Tailscale** (só se for usar o app iOS GeoMobile).

---

## 3. Bring-up L0 + L1 (near-verbatim)

```
# 1. HERMES_HOME — para novo dono em máquina própria, o default ~/.hermes serve.
export HERMES_HOME="$HOME/.hermes"

# 2. Hermes upstream pinado
git clone <hermes-agent> ~/.hermes/hermes-agent && cd $_
git checkout v2026.7.1
uv pip install -e '.[all]'
git apply ~/ARCA/Forge/Geo/hermes/patches/P2-geo-context-append.patch   # P2

# 3. Camada Geo (a partir de um fork SANITIZADO do repo Geo — ver §5)
~/<geo-fork>/hermes/install.sh        # respeita HERMES_HOME

# 4. Reset de identidade (§4) e vault (§5) ANTES de subir os daemons.

# 5. launchd (§6) — reescrever paths absolutos + labels, depois load.
```

> **Sanitização obrigatória:** o repo Geo carrega SOUL/memórias/segredos do Gabriel. Para o clone, partir de um **fork limpo** (SOUL neutro, `.env.example`, sem auth WhatsApp, sem `Vault` embutido). Ver §5.

---

## 4. Reset de identidade — o gestor, não o Gabriel

Manter a **estrutura** do SOUL.md (é o que dá o comportamento), trocar o **conteúdo**:

- `SOUL.md` — reescrever `# Soul of geo` → nome do agente do gestor; Identity (nome, papel = gestor, 24/7); manter **Green/Yellow/Red zones**, **Daily operating loop**, e a regra única de acesso (vault filesystem-only). Ajustar canais (quem é o "owner").
- `memories/MEMORY.md` + `USER.md` — zerar; popular com perfil do gestor.
- `config.yaml`:
  - `soul.path` → `~/.hermes/SOUL.md` (symlink para o SOUL do gestor).
  - `platforms`/`telegram` ids → novos.
- `.env` — **todos novos**: `TELEGRAM_BOT_TOKEN` (bot novo), `TELEGRAM_ALLOWED_USERS`/`_HOME_CHANNEL`, `EMAIL_ADDRESS`/`EMAIL_PASSWORD`, chave da lane LLM, `GEO_API_TOKEN`.
- Chat-id hardcoded `5225262193` (`context_scraping.py:56 GABRIEL_TELEGRAM_CHAT_ID` + job `reflexao-noturna` em `cron/jobs.json`) → id do gestor.

---

## 5. Vault — reusar o Obsidian do gestor

O geo espera um vault com `Blocks/**.md`, `Tasks/<uuid>.json`, `Captures/YYYY-MM-DD/`, `Index/blocks.sqlite`.

**Recomendação (mais simples): apontar o vault do gestor como `~/Vault`.**
- Se aceitável, symlink/mover o vault dele para `~/Vault` — zero edição de código.
- Senão, o vault path está **hardcoded em 6 lugares** (só `geo_write.py` respeita `GEOVAULT_DIR`); editar todos:
  - `geo-tools/_fs.py:21` `GEO_HOME = Path.home() / "Vault"`
  - `geo-tools/tools_write.py:54` `BLOCKS_DIR`
  - `geo-tools/tasks_fs.py`, `maintenance_dedup_tasks.py`, `destructive.py`
  - `scripts/geo_indexer.py:14`
  - (`guard.py` também proíbe o path legado `~/Library/Application Support/Geo/` — revisar as guardas para o novo path.)

**Scaffolding:** garantir `Blocks/`, `Tasks/`, `Captures/`, `Index/`, `Financeiro/` (§7) existem no vault antes do primeiro boot.

**Obsidian como visualizador:** já funciona (Markdown). Recomendado instalar **Dataview** para as views de tarefas/financeiro (§7.4) e **Calendar**. O indexador FTS (`geo-indexer`) é cache do agente, independente do Obsidian.

---

## 6. WhatsApp READ-ONLY — tarefas + financeiro

O ingest do geo é **exatamente** o pedido: daemon Baileys (`~/.hermes/whatsapp-ingest/ingest.js`) que só **lê** (`platforms.whatsapp.enabled: false` → nenhum outbound). O pipeline:

`ingest.js` → `wa_ingest.jsonl` → cron **context-scraping** (`context_scraping.py`, `0 21 * * *`) → blocos/tasks no vault.

**Passos:**
1. Parear o WhatsApp do gestor (QR em `whatsapp-ingest/auth/last-qr.txt`). Read-only ⇒ o próprio número dele como fonte é OK (o alerta "nunca a conta pessoal como bridge" vale para **outbound**, que aqui está desligado).
2. Re-apontar ids hardcoded (`GABRIEL_TELEGRAM_CHAT_ID`, JIDs no `.env`/config).
3. **Adaptar `context_scraping.py`** para extrair 2 classes:
   - **Tarefas** (já existe) → `geo_upsert_task`.
   - **Sinais financeiros (novo path):** valores, PIX, boletos, cobranças, pagamentos → `geo_record_transaction` (§7). Manter a garantia read-only: nenhuma resposta/confirmação outbound.
4. **Checklist de re-apontamento L2 (canônico):**
   - **Identidade/segredos:** `SOUL.md`, `memories/{MEMORY,USER}.md`, `.env`.
   - **Isolamento/paths:** `HERMES_HOME`, plists `ai.hermes.*`/`ai.geo.*` (paths `/Users/…` + labels únicos), repo fonte.
   - **Vault:** `~/Vault` (ou os 6 hardcodes).
   - **Telegram:** chat-id + allowed users + home channel.
   - **Email (himalaya):** `~/.config/himalaya/config.toml` + itens Keychain (`himalaya-<conta>`) → contas do gestor.
   - **WhatsApp:** `whatsapp-ingest/auth/` (re-parear), self-JID no config.
   - **GeoBridge/Tailscale (opcional, só p/ app iOS):** IP tailnet `100.123.44.9`, tokens `geobridge*.token`, `GeoMobile/Shared/Secrets.swift`, provisioning iOS.
   - **Máquina:** `/Applications/CuaDriver.app`, `/opt/homebrew/bin/node`, `venv/bin/python`.
   - **NÃO copiar:** `ai.omni.watch` / `~/Lab/omni-watch/` — é o projeto Omni, não faz parte do geo.

---

## 7. Módulo financeiro (NOVO) — contas + agregação

Objetivo: "acompanhar contas bancárias e o financeiro geral, **somado no sistema dele junto com o hermes**". Ou seja: dados financeiros **nativos do vault**, consultáveis pelo agente **e** visíveis no Obsidian — um único sistema.

### 7.1 Modelo de dados (no vault)
Área `Financeiro/` no vault, espelhando o padrão Tasks (JSON) + bloco rolante (padrão "Diário de contexto"):
- **Contas:** `Financeiro/accounts/<slug>.json` — `{ id, banco, tipo, apelido, saldo, moeda, atualizado_em }`.
- **Lançamentos:** `Financeiro/transactions/<uuid>.json` — `{ id, data, valor, sinal, categoria, conta_id, descricao, origem (whatsapp|openfinance|manual), dedup_key }`.
- **Visão geral:** bloco rolante único `Blocks/Financeiro — visão geral.md` — saldos por conta + fluxo do mês + alertas; regravado pela sync (§7.3). É o que o agente cita e o Obsidian mostra.

### 7.2 Tools novas (plugin `geo-finance`, espelhando geo-tools + `guard.py`)
`geo_upsert_account`, `geo_record_transaction`, `geo_get_balance`, `geo_list_transactions`, `geo_categorize`, `geo_finance_summary`. Layer-guard igual ao geo-tools (só escreve dentro de `Financeiro/`).

### 7.3 Fontes de ingest (direção real, contexto BR)
1. **WhatsApp read-only (já):** extração de PIX/boleto/valor no `context_scraping.py` → `geo_record_transaction(origem=whatsapp)`.
2. **Contas bancárias — Open Finance.** **Recomendado: Pluggy** (agregador BR dominante; conectores p/ Itaú, Nubank, Santander, BB, Bradesco, Inter etc.). Alternativas: **Belvo**; **import OFX/CSV** de extrato (zero-integração, esforço manual); **API direta do banco** (ex.: Santander, como o Omni faz — maior esforço). Direção: **Pluggy + job diário** por cobertura/esforço; OFX como fallback offline.
3. **Manual via chat** ("gastei 200 no mercado") → `geo_record_transaction(origem=manual)`.

Cron novo **`finance-sync`** (espelha o job `context-scraping`, `no_agent` ou prompt-agent): puxa saldos/lançamentos do Pluggy, **dedup** por `dedup_key`, **categoriza** (regras + LLM), regrava a visão geral e os saldos por conta.

### 7.4 Agregação / visualização
- O agente lê `geo_finance_summary` → responde "quanto tenho / gastei este mês / contas a pagar".
- Obsidian **Dataview** sobre `Financeiro/transactions/` → dashboards (fluxo mensal, por categoria, saldo consolidado).
- Alertas (saldo baixo, gasto acima da média) via o canal do gestor (Telegram/WhatsApp-ingest não envia; alerta sai pela lane owner).

### 7.5 Fasing do financeiro
- **F0** — storage `Financeiro/` + plugin `geo-finance` + entrada manual. (menor)
- **F1** — extração financeira no WhatsApp read-only.
- **F2** — conector Pluggy + `finance-sync` diário (dedup + categoriza).
- **F3** — dashboards Dataview + alertas de saldo/overspend.

---

## 8. Bring-up final + smoke test

1. `launchctl load` dos plists reescritos; `hermes` responde.
2. `geo-tools` registrado (tools `geo_*` disponíveis); vault read/write ok (criar/ler um bloco).
3. `whatsapp-ingest` pareado e **read-only** (aparece linha no `wa_ingest.jsonl`, zero outbound).
4. `context-scraping` roda → gera task e (F1) lançamento a partir de mensagem de teste.
5. `geo_record_transaction` grava um lançamento; `geo_finance_summary` soma; Obsidian mostra via Dataview.
6. `geo-indexer` reconstrói o FTS; busca do agente encontra o bloco novo.

---

## 9. Decisões abertas (confirmar com o gestor)

1. **Nome/persona** do agente (substitui "geo").
2. **Lane de chat LLM** — `openai-codex` (como o geo), Claude, ou chave própria do gestor.
3. **Vault** — mover o vault dele para `~/Vault` (simples) **ou** editar os 6 hardcodes p/ manter o path atual.
4. **Ingest bancário** — Pluggy (recomendado) vs OFX/CSV vs API direta do banco. Custo (Pluggy é pago) vs esforço.
5. **Canal primário** — Telegram, WhatsApp-ingest (read-only, não envia), ou TUI local. Envio de alertas precisa de uma lane outbound.
6. **App iOS (GeoMobile)** — sim/não (puxa Tailscale + GeoBridge + provisioning).

---

## 10. Escopo & esforço

- **Clone (L0+L1+L2 reset):** mecânico, alto valor, baixo risco — reusa `install.sh`. Maior custo humano = pareamentos (QR, keychain, bot Telegram, provisioning).
- **Financeiro (L+):** net-new. F0/F1 baratos (vault + tools + extração). F2 (Pluggy) é o item com dependência externa/custo. F3 é polish.
- **Fora de escopo do clone:** `ai.omni.watch` (Omni), qualquer dado/segredo do Gabriel.
