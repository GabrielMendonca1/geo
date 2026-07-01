# Track: Calendar SOTA — task→Apple Calendar mirror

Data: 2026-07-01. Objetivo: tornar o espelhamento task→EKEvent **estado-da-arte** — zero duplicata, metadata invisível, cores distintas, all-day/recorrência corretos, reconciliação robusta. Baseado em swarm de pesquisa web (5 agentes, fontes Apple docs/WWDC/forums citadas abaixo).

## Sintomas que originaram o track
1. Academia **duplicada** no iPhone (uma all-day + uma timed). Raiz: `.futureEvents` faz **SPLIT** de série.
2. **4 cores parecidas** (azul/roxo são hues vizinhos).
3. `geo:kind=task;id=...` **visível e feio** no notes do evento.

## Decisões guiadas pela pesquisa (o "porquê")

### D1 — Cores: per-calendar only, retunar paleta
EventKit **não tem cor por evento** (`EKEvent`/`EKCalendarItem` não têm propriedade de cor); cor só em `EKCalendar.cgColor`. Fantastical/Structured fazem multi-cor com **store próprio + render in-app**, não via EventKit. CalDAV não carrega cor por evento — nem o Apple Calendar nativo faz.
→ **Manter 4 calendários**, retunar com paleta colorblind-safe (Wong), variando **hue E luminosidade**: Tarefas `#0072B2` azul · Marcos `#E69F00` laranja · Hábitos `#009E73` verde-azulado · Eventos `#CC79A7` magenta (tira o roxo que lê como "azul"). Testar no tamanho real do chip.
→ Futuro opcional: cor real por evento só renderizando in-app (store próprio) — fora de escopo agora.

### D2 — Metadata: notes → `event.url` (invisível no iOS)
`EKEvent` não tem dicionário custom/`userInfo`. Os únicos campos graváveis string-like: `notes` (VISÍVEL no iPhone) e `url` (NSURL, **não renderizado no Calendário do iOS**). `calendarItemExternalIdentifier`/`eventIdentifier` são read-only e **instáveis** (mudam em sync/Exchange; recorrentes compartilham).
→ Gravar identidade em **`event.url = x-geo://task/<uuid>`** (esquema namespaced — evitar `geo:` puro, é RFC 5870). **Limpar o notes.** App DB = source of truth; guardar `eventIdentifier` de volta na task. Nunca usar `externalIdentifier` como chave primária.

### D3 — Recorrência / o dup: `.futureEvents` é split (WWDC 2010 s.136)
`.futureEvents` **trunca a regra antiga + cria série NOVA independente** (a duplicata). Mudar `isAllDay` joga o start pra meia-noite → as séries não colapsam → dup visível. **Não existe `.allEvents`.** Detached → salvar/remover com `.thisEvent`.
→ Bug latente: `EventKitAdapter.applyPlan` usa `.futureEvents` p/ hábito → pode splitar em qualquer edição.
→ **Fix canônico**: p/ mudar propriedade da série inteira, **deletar a série (`remove` com `.futureEvents` a partir da 1ª ocorrência) e recriar** um único recorrente. **OU** (recomendado p/ task-mirror) **espelhar por-instância**: um EKEvent por ocorrência com chave `taskUUID#YYYY-MM-DD` — elimina occurrence destacada, dup e a complexidade de span.

### D4 — Upsert idempotente em 3 camadas (mata duplicata)
EventKit não tem upsert. Ao espelhar uma task, resolver o evento existente nesta ordem:
1. `event(withIdentifier: storedEventId)`
2. miss → busca por predicate na janela da task + match do `<uuid>` no `event.url`
3. miss → **criar**. Depois re-persistir o `eventIdentifier`.

### D5 — Loop de reconciliação (na abertura + `EKEventStoreChanged`)
`EKEventStoreChanged` **não traz diff** → re-query da janela é o único caminho correto (debounce, off-main). Varrer o calendário-espelho numa janela rolante (−1mês…+3meses):
- evento-espelho cujo `<uuid>` não mapeia p/ task viva → **órfão → deletar**.
- task viva sem evento na janela → **recriar**.
- one-way: divergência = drift, app sobrescreve. **Tombstone** curto no delete p/ um `EKEventStoreChanged` atrasado não ressuscitar cópia.
- gate: rodar só **após `loadTasks`** (nosso gotcha de ordering).

### D6 — All-day correto (VERIFICAR empiricamente)
⚠️ Conflito de fontes: pesquisa diz **`endDate` de all-day é INCLUSIVO** (1 dia = start e end no MESMO dia; `start+1dia` = evento de 2 dias). Nosso código atual faz `end = start+1dia` com comentário "end==start lança". **Verificar no device**: criar all-day same-day vs +1dia, observar iPhone. Ajustar. Também: **`timeZone = nil` p/ all-day** (evita shift e um crash conhecido com tz+isAllDay); `startOfDay` via `Calendar`, nunca aritmética de `Date()`.
→ Substituir a heurística sentinela `00:00`/`23:59` por um campo **explícito** no `TaskBody` (ex: `hasTime: Bool` / âncora opcional) — mais limpo e à prova de fuso que adivinhar pela hora.

### D7 — Idempotência de calendário (mata o dup de calendário)
Persistir `calendarIdentifier` por tipo; `calendar(withIdentifier:)` resolve-first; fallback scan por título na source; **serializar** criação; preferir source iCloud. Dup de calendário vem de id não-persistido + **race entre instâncias** do app (`pkill -x Geo`, 1 instância).

### D8 — Permissão + assinatura
Reconciliação **exige Full Access** (write-only não lê o que gravou → não dá p/ dedup). Re-sign ad-hoc troca a Designated Requirement → **TCC thrash** (o popup a cada rebuild). Fix real: **assinar com identidade estável** (Apple Development/Developer ID, bundle id constante) e parar de re-assinar. `tccutil reset Calendar <bundle-id>` só quando preciso.

## Questão de modelo (levantada pela pesquisa)
Amie usa **Apple Reminders** p/ tasks (store semanticamente correto) e Calendar só p/ time-blocks. Structured = app SoT, Apple read-only, **sem** two-way. Vale decidir: tasks sem hora devem mesmo virar evento all-day, ou isso polui? Decisão atual do Gabriel: **manter no Calendar** (quer ver no iPhone). Mantido, mas registrado o trade-off.

## Fases (p/ /g-loop)

**F0 — Quick wins (cirúrgico, baixo risco) ✅ 2026-07-01 (VIOLATIONS=0)**
- [x] Retunar as 4 cores (paleta Wong) — `calendarColor(for:)` + aplicado nos 4 calendários existentes.
- [x] Metadata `notes`→`event.url` (`x-geo://<kind>/<id>`), notes limpo — `mirrorPlan`/`configure`.
- [x] Recorrente: `mirror(task:)` faz **delete-série+recria** (guarda `recurringEvent(matches:)` evita churn); `applyPlan` removido; `.futureEvents` split neutralizado.
- [x] Duplicata: era transiente de sync (Mac/iCloud sempre teve 1 série); verificado 1 série all-day.
- Verify: cores 4/4 Wong · notes geo:=0 · url=0 (removida do evento — visível no macOS) · academia=1/dia · 48 all-day span=1dia.

**Correção pós-device-check (2 rodada):**
- **A "duplicata" era all-day de 2 dias:** `end = start+1dia` renderiza 2 dias (endDate INCLUSIVO no EventKit — testado macOS 26). Fix: `plan(forAnchor:)` usa `end = dayStart`. `end==start` salva e renderiza 1 dia (comentário antigo "lança" era falso). Nunca houve dup real de série (1 `calendarItemIdentifier`).
- **Metadata fora do evento:** `event.url` aparece no Calendar do **macOS** (só escondido no iOS). Removido (`url=nil`, `notes=nil`); identidade só no `externalEKEventID` do `.json`.
- **Reset limpo:** `removeCalendar` dos 4 + limpar ids + backfill único. Aprendizado: NÃO fazer re-mirror com múltiplos scripts sobrepostos (foi o que confundiu).
- ⚠️ **Cores:** limite do EventKit = cor é **por-calendário** (4 categorias = 4 cores; multi-cor por evento só render in-app). Wong aplicada; se ainda "não distinta" → paleta mais vívida ou render in-app.

**F1 — Robustez**
- [ ] Campo explícito `hasTime`/âncora opcional no `TaskBody` (aposentar heurística `00:00`/`23:59`).
- [ ] Upsert idempotente 3-camadas + match por `url`.
- [ ] Loop de reconciliação (launch pós-loadTasks + `EKEventStoreChanged` debounced, off-main) + tombstones + delete de órfãos.
- [ ] Verificar all-day inclusivo no device; `timeZone=nil`.

**F2 — Modelo de recorrência**
- [ ] Decidir per-instância (`taskUUID#data`, recomendado) vs `EKRecurrenceRule`+delete/recreate. Migrar hábitos.

**F3 — Assinatura estável**
- [ ] Identidade de assinatura estável p/ matar o re-prompt de TCC no rebuild.

Cada fase: implementar → build Debug+Release + **teste eu mesmo** (sandbox OFF, `CODE_SIGNING_ALLOWED=NO`) → **verificar no device** (cores/all-day/sem-dup) → iterar.

## Critérios de sucesso (goal-driven)
- Zero duplicata de evento/série após qualquer edição (incl. timed→all-day de hábito).
- notes limpo; `url` carrega o id; iPhone não mostra metadata.
- 4 cores nitidamente distintas no tamanho do chip do iPhone.
- Task sem hora = **um** evento all-day (não 2 dias, não timed).
- Reconciliação remove órfãos; delete não ressuscita.
- Rebuild não re-pede TCC (após assinatura estável).

## Fontes (swarm 2026-07-01)
- Cores: EventKit sem cor por evento — developer.apple.com/documentation/eventkit/ekcalendaritem · macworld.com/article/1378257 · paleta Wong colorblind.io/guides/colorblind-safe-palettes
- Metadata: `url` invisível no iOS — discussions.apple.com/thread/2409050 · learn.microsoft.com/dotnet/api/eventkit.ekcalendaritem.url · forum 6636 (ids instáveis)
- Recorrência/split: WWDC 2010 s.136 asciiwwdc.com/2010/sessions/136 · developer.apple.com/documentation/eventkit/ekspan
- Arquitetura: Structured/Amie/Akiflow · TN3153 · forum 6636 · EKEventStoreChanged (sem diff)
- Engenharia: WWDC23 10052 · TN3153 · all-day inclusivo+tz (forum 109374) · TCC/signing (forum 730043) · nemecek.be/blog/63
