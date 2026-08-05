# Geo — Lifecycle de Entradas v1 (design, 2026-07-20)

## Reconciliação com a sessão de curadoria (2026-07-20)

- **F2 muda de natureza:** a limpeza dos dados **não** é arquivamento em massa; é continuar o loop de curadoria cluster-a-cluster já em andamento na sessão "Geo Vault Cleaning" (clusters 7–22 pendentes, vereditos do Gabriel, soft-delete para `~/.geo-trash-20260707/`). A migração apenas unifica o destino (`trash` legado + `Blocks/.archive/` viram uma convenção só) e o ledger passa a cobrir o resultado.
- **Cadência do pipeline WhatsApp:** 1×/dia (decisão da sessão de curadoria via workflow de barra editorial) é canônica; os caps por ciclo da tabela de writers valem por run diário.
- **Sequenciamento anticolisão:** nenhuma edição em `context_scraping.py` até o workflow `w9rum6ug0` (barra editorial + cadência + dedup) aterrissar; F1 (`geo_write`) rebaseia em cima do arquivo patchado, preservando `expire_stale_tasks`.
- **Estado já executado pela curadoria (não refazer):** torneira "Contexto vivo" morta na raiz (15/07, 42 arquivos no trash), clusters 1–6 consolidados em hubs canônicos, correção societária Omni/BLOKO.

Esqueleto: proposta B (contrato-único via lib `geo_write`), com morte-por-default da A e as deleções da C. Tensões do debate resolvidas inline.

## Princípios

1. Arquivos são a verdade; a caneta é única. Toda mutação do grafo passa pela lib `geo_write` (Python, no repo `~/ARCA/Forge/Geo`). Ler é livre.
2. Determinístico decide forma; LLM decide conteúdo. Dedup, validação, layer, morte = código puro. Cron nunca depende de LLM para convergir.
3. Nada nasce imortal. Toda entrada automática tem TTL por type/kind. Imortalidade é privilégio da layer `user` e de promoção humana.
4. Automação nunca escreve layer `user` nem cria `permanent`, `literature`, `project` ou `milestone`. Hard-fail na lib, não convenção.
5. Morte é mover arquivo por regra de data em frontmatter (`created`/`updated`), nunca mtime, nunca delete. Reversível por construção.
6. Revisão humana é opcional, capada (≤10 itens, ≤10 min/domingo) e fail-safe: inbox ignorado = vault mais limpo, nunca mais sujo.
7. Cron silencioso é falha. Todo cron escreve heartbeat; o sweep audita os outros; o hook de contexto audita o sweep e verbaliza na conversa.

## Contrato de escrita

Lib `geo_write`, extraída do plugin geo-tools (que já tem layer guard e dedup de título). API fechada em 5 operações: `write_block`, `append_block`, `write_task`, `update_task` (complete|delete|expire), `add_occurrence`. Sem config file, sem hooks, sem plugin system; alvo ≤300 linhas. Escrita atômica (temp+rename) + `flock` em `Index/.write.lock`.

Identidades de writer (tabela hardcoded): `context-scraping`, `geo-agent`, `ios-bridge`, `sweep`. Só essas. Writer novo = editar a tabela = decisão consciente.

**Block** — frontmatter obrigatório: `id`, `type ∈ {fleeting, permanent, moc}` (automação só emite `fleeting`; `moc`/`permanent` só via `geo-agent` com flag humana), `layer ∈ {user, agent, review, shared}` (automação: só `agent`/`review`), `created`, `updated`, `created_by`, título não-vazio. Types `literature` e `project` continuam válidos para leitura/legado, mas nenhum writer os emite.
**Task** (`kind=task`) — `due` obrigatório sem exceção, `status ∈ {pending, completed}`, `created_by`, `created_at`.
**Event** — data obrigatória.
**Habit** — `rule` + `timeOfDay` obrigatórios; `occurrences[]` append-only; `status=completed` é rejeitado com erro — corrupção do checkbox vira inexpressável.
**Milestone** — só `geo-agent`; data-alvo obrigatória.

**Dedup técnico (sem LLM):**
- Task: título normalizado (lowercase, sem acento, espaços colapsados) contra pendings → reject com id do existente. `force_new` só no caminho interativo (`geo-agent`).
- Block camada 1: título normalizado exato contra blocks vivos → reject retornando id; o writer decide chamar `append_block` (a lib nunca faz merge silencioso).
- Block camada 2: simhash 64-bit do corpo (shingles de 3 palavras), Hamming ≤6 contra últimos 90d do mesmo type → writer automático: conteúdo vai como linha no `Diário de contexto.md` + item no inbox; interativo: pode `force_new`.
- Occurrence: dedup por (habit_id, dia).

**Auditoria:** `Index/ledger.jsonl`, append-only: `{ts, writer, op, entity, id, title_norm, simhash, result}`. É índice de dedup + telemetria de rejeições. Derivado, nunca autoridade: `rebuild-ledger` reconstrói do frontmatter; **rebuild agendado toda segunda 03:30** cobre edição manual do Gabriel no Obsidian/iOS (rename por fora do gate). Dedup com ledger ausente cai para scan direto.

**Bridge iOS** = entrypoint da mesma lib (bridge é Python — `ai.geo.bridge` repontado na migração Obsidian; confirmar na F1, é pré-requisito da F3): rota de escrita = parse + chamada da lib, zero validação própria. Leitores ficam fora do gate: daemon calendário (reader para sempre), indexer FTS, hook de contexto, Obsidian, GeoCapture (namespace `Captures/`, isento — documentar a isenção).

## Lifecycle por entidade

Executor: `geo-sweep` — Python puro, sem rede, **diário 03:00 via launchd `StartCalendarInterval`; se o Mac dormiu, o próximo run processa o backlog inteiro (regras por data são idempotentes, run perdido não perde morte, só atrasa)**. Destinos: `Blocks/.archive/YYYY-MM/`, `Tasks/.archive/YYYY-MM/` (unifica `.expired` e done). Todo move loga em `Logs/lifecycle-YYYY-MM.log` (greppable) e o agente sabe consultá-lo — resposta de um passo para "onde foi minha nota?". Leitores ignoram dot-dirs (mesmo filtro do fix sync-conflict). **Idempotência sob Syncthing: sweep re-arquiva por `id` no frontmatter, não por presença do arquivo — ressurreição por sync-conflict morre no run seguinte.** Escape universal: `pinned: true` → sweep nunca toca. **Circuit breaker: run que quiser arquivar >15% do vault aborta e alarma.**

| Entidade | Nascimento | Vida | Morte |
|---|---|---|---|
| block fleeting | qualquer writer, layer agent/review | `updated` < 30d = vivo; append renova | 30d sem toque → archive |
| block permanent/moc | só humano/geo-agent | imortal | nunca auto-expira; órfãos → inbox trimestral |
| block layer user | só Gabriel | imortal | fora do alcance do sweep, sempre |
| task pending | writers com due | até due | vencida >7d → archive com `status: expired` + linha no diário |
| task completed | — | 30d como contexto | >30d → archive |
| event | writers com data | até a data | data+3d → archive, sem inbox (nada a decidir) |
| habit | só explícito (ver abaixo) | occurrences append-only | 30d sem occurrence → `status: paused` + inbox; paused 60d → archive (histórico preservado) |
| milestone | só geo-agent | sem TTL | vencido → inbox até decisão humana (única entidade fail-open — auto-expirar seria desistir dos objetivos do dono) |

Singletons rolantes (`Diário de contexto.md`, blocos-pessoa): superfícies, não entradas — sem TTL, lista fechada na lib, cap de 8 linhas em pessoa vira regra da lib.

**Revisão humana:** `Blocks/Inbox de revisão.md` (layer review), sobrescrito pelo sweep dominical, cap duro de 10 itens: (1) morre em ≤7d, (2) sugestões de promoção (fleeting ≥2 backlinks), (3) milestones vencidos, (4) rejeitados por cap/simhash na semana, (5) heartbeats vermelhos. Custo: ~10 min/domingo, zero obrigação. Archive é indexado no FTS sob flag `--archived` — morte reversível também por busca, não só por filesystem.

## Hábitos ponta a ponta

Semântica única: hábito nunca "completa"; progresso = `add_occurrence(habit_id, date)`, dedup por dia; streak computado **on-read em um único lugar** (tasks_fs — a docstring vira código em vez de mentira).

- **Lib**: `status=completed` em habit = erro. Única forma de escrever ocorrência no sistema.
- **Bridge**: `POST /habits/{id}/occurrence` → lib; listagem devolve streak computado.
- **App iOS (F3)**: checkbox de hábito chama a rota de occurrence (mata a corrupção por inexistência do caminho errado); UI mostra streak da bridge, não recalcula; criação de hábito na aba nova, voz-first.
- **geo-tools/WhatsApp**: tool de registrar ocorrência de hábito existente; **criação por DECIDE/WhatsApp congelada até a aba do app existir** — hábito é compromisso, não inferência.
- **Calendário**: não espelha hábito. Streak não é calendárico; 6-7 eventos/semana no pool `Geo · N` é ruído.
- Academia: 21 ocorrências arquivadas; import opcional na F3 se Gabriel quiser o streak histórico.
- **Cláusula de saída (do debate): 60d pós-F3 sem hábito vivo → aplicar a subtração da C (matar o kind).**

## Writers

| Writer | Veredito | Mudança |
|---|---|---|
| context_scraping | mantém | adota `geo_write`; cap ≤3 blocks e ≤3 tasks/ciclo (excedente → diário + inbox seção 4); colisão de título → append no existente; **perde** o sweep de expiração (vai pro geo-sweep) |
| email-triage | **morre (F0)** | viola hard rule há semanas sem ninguém notar = valor zero comprovado. Desligar, não repontar. Pendentes válidas do store legado: triagem única de import pro vault via lib; store nunca mais tocado. Se e-mail acionável doer em 2 meses, religa pelo caminho único |
| reflexao-noturna | **morre (F0)** | sem dedup, sem cap, função coberta pelo diário + continuidade-pessoa. Deleção pura, revert barato |
| manutencao-slipbox | **morre (F0)** | não consertar o Connection error; substituído por geo-sweep (determinístico) + curadoria on-demand do agente (promoção/merge é julgamento; julgamento agendado sem supervisão gerou os clusters) |
| plugin geo-tools | mantém | doa código pra lib e passa a chamá-la; ganha tools de hábito; bloqueado de emitir permanent/literature/project |
| bridge iOS | mantém | vira entrypoint da lib em toda rota de escrita; ganha rota de occurrence e streak on-read |
| GeoCapture | mantém intacto | namespace isolado; única adição: `Captures/` >90d → archive via sweep |

## Manutenção & observabilidade

- **geo-sweep** (diário 03:00, determinístico): moves da tabela de lifecycle, inbox (domingo completo, dias úteis só contadores), rebuild-ledger (segunda), auditoria de heartbeats, métricas. Padrão omni-cron-silent-fail: fail-fast na precondição + contador de falhas consecutivas escalando severidade.
- **geo-curate** (LLM, on-demand ou dominical best-effort via agente): merge de near-dups sinalizados pelo ledger, sugestões de promoção. Se falhar, o sistema converge só com o sweep — correção estrutural do faxineiro quebrado.
- **Heartbeats**: cada cron escreve timestamp em `Logs/heartbeats/<nome>`. Sweep audita: idade >2× período → linha vermelha no inbox e em `Blocks/Saúde do vault.md`. O sweep é auditado pelo hook de contexto (heartbeat >48h → agente verbaliza na próxima conversa — canal que existe; Telegram foi removido). Risco Gabriel-viajou aceito (ver Riscos).
- **`Blocks/Saúde do vault.md`** (layer agent, sobrescrito diário): contagem por layer/type, delta 7d/30d, dup-rejects por writer, pending count, heartbeats. Piso greppable: linha semanal `[geo-sweep] blocks: N | merges: M | tasks vivas: P | arquivadas: A | violações: 0` no diário.
- **Guarda anti-regressão**: sweep alarma se o store legado receber arquivo novo ou existir block sem `created_by`.
- Limiares de alarme: review >30 blocks; pending >15; crescimento líquido >+40/mês; writer estourando cap em >50% dos ciclos.
- **Goldens (lacuna que as três propostas deixaram)**: suíte da lib (cada writer-identity × operação × rejeição, reproduzindo a assinatura real de chamada — lição Clarissa) + golden do sweep contra vault-fixture, incluindo caso de ressurreição por sync-conflict. Rodam no repo, sem CI nova.

## O que morre

- Crons email-triage, reflexao-noturna, manutencao-slipbox (F0, deleção).
- Escrita no store legado de tasks — para sempre; guarda ativa no sweep.
- Emissão automática de `permanent`, `literature`, `project`, `milestone`.
- `Tasks/.expired/` como destino separado (unifica em `Tasks/.archive/YYYY-MM/` com `status: expired`); `Tasks expiradas.md` vira linha no diário.
- Dedup por julgamento de LLM contra manifest.
- Checkbox iOS marcando hábito como completed.
- Docs stale: CLAUDE.md "4 calendários por tipo" → pool `Geo · 1..6` por hash djb2; docstring de streaks do tasks_fs (vira código).

## Migração

- **F0 — estancar (1 sessão)**: desligar os 3 crons; triagem única do store legado (pendentes válidas → vault). *Aceite: store sem escrita nova em 24h; launchd sem os 3 jobs.*
- **F1 — gate (1-2 dias)**: extrair `geo_write` do geo-tools (schema, layer guard, dedup título+simhash, ledger, flock); context_scraping e geo-tools adotam; caps ativos; goldens verdes; confirmar stack Python da bridge; corrigir docs stale. *Aceite: goldens passam; 3 dias sem block novo colidindo com slug existente; ledger registrando dup_rejects.*
- **F2 — limpeza dos dados atuais:** continuar o loop de curadoria cluster-a-cluster da sessão "Geo Vault Cleaning", usando os clusters 7–22 e os vereditos do Gabriel como instrumento; unificar o `trash` legado e `Blocks/.archive/` em uma única convenção de archive; ao final, rebuild FTS e ledger. Nada deletado. *Aceite: 22/22 clusters aplicados ou Gabriel declara o loop encerrado; destino de archive unificado; FTS e ledger reconstruídos sobre o resultado.*
- **F3 — aba nova do app**: bridge com rotas de escrita via lib + occurrence + streak on-read; iOS com checkbox correto, criação de hábito por voz, leitura do inbox; primeiro hábito de teste (Academia, import opcional). *Aceite: criar hábito por voz, marcar 2 dias, streak=2 na UI, JSON sem status=completed.*
- **F4 — regime**: geo-sweep + heartbeats + Saúde do vault ligados; 30d depois, revisar limiares e aplicar a cláusula de saída dos hábitos se for o caso. *Aceite: 4 semanas com violações=0, review ≤30, pending ≤15, heartbeats verdes.*

## Riscos aceitos

1. Caps engolem sinal em dia denso — mitigado por excedente no diário + inbox seção 4 + `force_new`; falso-negativo ocasional < estado atual.
2. Simhash não pega paráfrase distante — fica pro geo-curate; sem dedup semântico/embedding (engenhosidade acima da necessidade).
3. Inbox cronicamente ignorado — modo de falha seguro por design (tudo no archive, pesquisável); vault fica menos rico, tese lifecycle assumida.
4. Sweep como single point de convergência — intencional; protegido por circuit breaker, fail-fast, heartbeat auditado pelo hook.
5. Auditor final é a conversa — Gabriel viajando 2 semanas = alarme não lido. Aceito; segundo canal só se doer.
6. Merge errado por colisão de título com assunto distinto — writer decide o append (nunca a lib), erro visível e corrigível.
7. E-mail acionável perdido pós-morte do triage — teórico por preferência revelada; porta de retorno pelo caminho único.
8. Hábitos fail-closed podem quase não nascer — preferível a hábitos-fantasma; cláusula de saída de 60d cobre o cenário.
