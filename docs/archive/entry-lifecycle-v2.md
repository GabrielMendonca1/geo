# Geo — Lifecycle de Entradas v2: imutável, singular, instantâneo (design, 2026-07-20)

Supersede o miolo do v1 após feedback do Gabriel: dedup por similaridade é remendo; cadência 1×/dia mata o "agente antenado". v2 torna duplicata inexpressável por construção e devolve o tempo real. Sobrevivem do v1: caneta única, guard da layer `user`, lifecycle/expiração de tasks, hábitos fail-closed, crons mortos, ledger.

## Princípios
1. Fatos são imutáveis. Toda observação vira linha append-only num log, chaveada pela origem (message-id). Reprocessar nunca duplica: idempotência estrutural, não heurística. Simhash e dedup por similaridade MORREM.
2. Conhecimento é singular. Uma entidade canônica por pessoa/projeto/tema; a view .md é REGENERADA por destilação do log (função dos fatos), nunca acumulada por appends cegos.
3. Ruído morre na fonte. Tier por chat (core/watch/noise) decidido pelo Gabriel no onboarding; nada de LLM caro em grupo-noise.
4. Antenado = hook. O geo-context injeta cauda do log + views relevantes + topo do board. Ciência de minutos, sempre.
5. O que o Gabriel vê é uma lente curada. Board top-10 administrado pelo hermes; o resto existe mas não grita (anti-ansiedade é política de exibição, não de captura).
6. Duas velocidades: ingest instantâneo e barato (sem LLM pesado); destilação assíncrona (LLM) quando a entidade acumula fatos novos.
7. Files are truth, filesystem-only, automação nunca escreve layer `user` (inalterados do v1).

## Componentes
### Log de fatos — `~/Vault/Log/facts-YYYY-MM.jsonl`
Append-only. Linha: {ts, source: {chat, msg_ids}, tier, entities: [ids], text, kind: fact|task_signal|urgent}. Chave de idempotência = msg_ids (o wa_ingest.jsonl do sidecar já é o log bruto imutável; facts é a camada derivada, também imutável). Nunca editado, nunca deletado; rotação mensal.

### Registro de chats — `~/Vault/Config/chats.yaml`
Nasce no ONBOARDING: sessão em que o Gabriel dá veredito por chat ativo (30d): `core` (fatos + tasks + urgentes), `watch` (só fatos/contexto), `noise` (ignorado). Agente PROPÕE mudanças de tier (item no board), nunca aplica sozinho. Chat novo sem veredito = watch por default.

### Ingest contínuo (substitui o cron de 30min/1×dia)
Tick leve (≤5min) ou streaming do sidecar: mensagens novas de chats core/watch → classificador barato (Haiku) roteia: fato→log (com entities candidatas), sinal de task→fila de destilação, urgente→DM. Sem escrita de blocks aqui. Custo por mensagem ~zero para noise (filtrado antes do modelo).

### Entidades singulares — `~/Vault/Blocks/` (materialização)
Frontmatter ganha `entity_id` estável e `entity_status: provisional|confirmed`. View = destilação do log filtrado por entity_id + o conteúdo confirmado existente; regenerar é idempotente. Entidade sem match no roteamento nasce `provisional` e aparece pro Gabriel promover/fundir (um toque). Notas layer `user` seguem intocáveis e fora da regeneração.

### Destilação assíncrona (o novo papel do DECIDE)
Dispara quando entidade acumula N fatos novos (default 5) ou T (default 2h) desde o último fold. Regenera a view da entidade; decide criação de task a partir dos task_signals (barra v4 mantida: verbo+dono+prazo; dedup por msg_ids de origem — estrutural). Diário de contexto continua como digest diário derivado do log.

### Board de tasks — `~/Vault/Tasks/board.json` + view `Blocks/Board.md`
Seções: `user` (top ≤10, ordenadas por importância real — administradas pelo hermes: promove por due próximo/contexto quente, demove o que esfriou), `depois` (default oculto), `radar` (longe/simples, agrupadas). Regras anti-ansiedade: default view = só `user`; horizonte ≤7d salvo importância alta; tarefas triviais agrupadas numa linha. O board é view rebuildable (truth = Tasks/*.json); hermes reordena via caneta única; app iOS (F3) exibe o board, não a lista crua.

### Hook geo-context
Injeta: (a) board seção user; (b) views das entidades relevantes à conversa (match por menção); (c) cauda do log (últimas 12h, compactada). É o mecanismo do "antenado instantaneamente".

### Caneta única (geo_write v2)
API evolui: append_fact(source, ...) [idempotente por msg_ids], upsert_entity_view(entity_id, content) [regeneração], write_task/update_task/add_occurrence (inalterados), update_board(sections). Remove: simhash, dedup por título contra blocks (substituído pelo registro de entidades), caps como mecanismo primário (viram guard-rail de segurança: alarme se um fold quiser criar >10 entidades). Ledger mantém (telemetria/auditoria).

## Lifecycle
- Fato: imortal no log (rotação mensal de arquivo, nunca de conteúdo).
- Entidade confirmada: view viva regenerável; sem TTL.
- Entidade provisional: 30d sem promoção nem fato novo → arquivada (view movida pra .archive/), reversível.
- Task: inalterado do v1 (due obrigatório, vencida >7d expira pra archive, completed >30d archive futuro no sweep F4).
- Hábito: inalterado (occurrences append-only; nunca completa).

## O que morre (além do v1 já morto)
- Simhash e todo dedup por similaridade.
- Cadência 1×/dia (o cron context-scraping é substituído pelo ingest contínuo + destilação assíncrona).
- DECIDE como criador de blocos avulsos.
- Caps 3/3 como mecanismo central (viram alarme).

## Migração
- M1 Onboarding: inventário de chats 30d (volume+amostras) → vereditos do Gabriel → Config/chats.yaml. Aceite: todo chat ativo com tier.
- M2 Log + ingest: facts.jsonl + tick leve idempotente; cron antigo desligado. Aceite: mesma mensagem processada 2× = 1 fato; fato de chat core aparece no log ≤5min.
- M3 Entidades: registro inicial derivado da curadoria (clusters já consolidados = entidades confirmadas); roteamento fato→entidade; destilação assíncrona regenerando views; DECIDE-blocos desligado. Aceite: view regenerada 2× = byte-idêntica; entidade nova nasce provisional.
- M4 Board + hook: board.json + política anti-ansiedade + hook injetando log tail/views/board. Aceite: hermes responde "o que aconteceu hoje?" citando fato de ≤10min; board user ≤10.
- M5 App (F3): aba de tasks = board; hábitos com occurrence+streak via bridge.

## Riscos aceitos
1. Classificador barato erra tier de fato → fato perdido em watch/noise; mitigado por onboarding revisável e log bruto do sidecar preservado (reprocessável).
2. Regeneração de view depende de LLM → view pode atrasar (fatos no hook cobrem o gap).
3. Board curado esconde task que o Gabriel queria ver → seção `depois` a um toque; hermes aprende do feedback.
4. Entidades provisionais acumulam se o Gabriel ignorar → TTL 30d as arquiva sozinho (fail-safe do v1 mantido).
