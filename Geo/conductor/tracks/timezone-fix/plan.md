# Track: timezone-fix (loop A+B)

Fonte de verdade deste trabalho. Bug: "reunião 14:50" vira 11:50 — LLM/agent carimba hora local como UTC (`Z`) sem somar +3h; e `event start/end` passam crus (sem normalização). Display é determinístico (Swift decoda `.iso8601`→Date, renderiza em `Calendar.current` = São Paulo).

## Goal
Tirar a conta de fuso do LLM. Um resolvedor determinístico converte hora LOCAL naive → UTC em todo caminho de escrita. Item auto-descritivo (`isAllDay` explícito) mata a sentinela mágica. Date-only e timed aterrissam no horário certo no app + Apple Calendar; tasks antigas continuam legíveis.

## Verify
`python3 tests/geo_time_contract.py` (contrato Python) + XCTest do Geo quando `.swift` mudar (`xcodebuild -project Geo.xcodeproj -scheme Geo -destination 'platform=macOS' test`). DONE = harness 0 falhas + XCTest verde.

## Fase A — resolvedor determinístico (Python) [DONE ✓ harness 7/7]
- [x] `_normalize_anchor` (tasks_fs.py): naive → LOCAL_TZ; explicit tz honrado.
- [x] rotear `event start/end` por `_normalize_anchor`.
- [x] normalizar `date` de reminder absoluto (`_trigger` + `_normalize_reminders`) — senão naive quebra Swift `.iso8601`.
- [x] `whatsapp-extractor.py` `_resolve_due`: naive → local (`tz`).
- [x] schemas `tools_write.py` (6 campos × 2 cópias + reminders + add_reminder `at`): hora LOCAL naive, sem Z.
- [x] prompt DECIDE (`whatsapp-extractor.py`) + **SOUL.md** (contradizia: "always convert local→UTC"): hora LOCAL naive.
- [x] sync fonte → vivo (cp cirúrgico dos 3 .py; SOUL é symlink). Harness verde no vivo também.
- ⚠️ ATIVAÇÃO: gateway vivo carrega plugin/SOUL no boot → precisa `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway` (derruba sessões Telegram alguns seg) pra ativar no agent ao vivo. Cron extractor pega no próximo tick sozinho.
- Fora de A: `email-extractor.py` (só-vivo, já date-only-only); `close-day.py`/`geo_context` (loops separados).

## Fase B — dado auto-descritivo `isAllDay` (Swift + Python) [implementado, build rodando]
Decisão: `isAllDay` **top-level opcional no `TaskItem`** (não no enum `TaskBody`) — cirúrgico, mesmo precedente do `externalEKEventID` (reconciliação top-level).
- [x] `TaskItem` (GeoCore): campo `isAllDay: Bool?` + CodingKey + `decodeIfPresent` (backward-compat, nil omitido no encode) + `resolvedIsAllDay` (flag ?? inferência de sentinela local 23:59/00:00).
- [x] `EventKitAdapter.mirrorPlan`: usa `task.resolvedIsAllDay`; `plan(forAnchor:isAllDay:)`; removido `isDateOnly()`; evento honra flag all-day.
- [x] `DayAgendaViewModel`: rows usam `task.resolvedIsAllDay` (antes hardcoded false).
- [x] writers Python setam `isAllDay` (`tasks_fs._create_single` via `_is_all_day`; `whatsapp-extractor.write_task_file`). Synced live.
- [x] XCTest: 4 casos (round-trip flag, omissão quando nil, fallback sentinela, override explícito).
- [x] `xcodebuild test`: **657 passed, 0 failed** (inclui os 4 novos de isAllDay). Ad-hoc sign (`CODE_SIGN_IDENTITY="-"`) porque o Keychain "Geo Local Signing" é inacessível na sessão background → `errSecInternalComponent`.
- ⚠️ B no live-agent: a escrita do `isAllDay` foi sincronizada DEPOIS do restart do gateway → ativa no PRÓXIMO restart; até lá o fallback `resolvedIsAllDay` (sentinela) mantém all-day correto. Cron pega sozinho. Sem ação urgente.

## Fase C — gate aceitar/recusar (inbox review) [depois de B, loop próprio]

## Limites / risco
15 iterações, stall 3. NEVER: enfraquecer asserções do harness; migrar destrutivamente Tasks/*.json; quebrar leitura de arquivos antigos; reiniciar gateway vivo sem ok; commit/force-push sem ok.

## Log
- it0: harness `tests/geo_time_contract.py` criado (contrato-alvo). Baseline: 6 falhas.
- it1: naive→local em `_normalize_anchor` + rotear event start/end → 6→? .
- it2: normalizar reminder absoluto + caso no harness → 7/7 verde.
- it3: schemas tools_write (6 campos ×2 + reminders + at) + DECIDE prompt + SOUL.md → contrato de instrução alinhado. Sync fonte→vivo. Harness verde source + live. **Fase A DONE.** Gateway reiniciado (A live).
- it4: B — `isAllDay` top-level no TaskItem (Codable backward-compat) + EventKitAdapter lê flag + DayAgendaViewModel + writers Python + 4 XCTest. Build: codesign errSecInternalComponent (Keychain bg) → ad-hoc. **657 passed / 0 failed. Fase A+B DONE.**
