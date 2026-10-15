# Rotinas autorizadas (fonte versionada, não publicada)

Fonte estática da ficha A/B/C/D aprovada pelo usuário em 2026-09-14. Nada aqui é estado vivo,
seed ou deploy: a publicação na VM continua sendo passo manual do agente principal.

| Arquivo | Conteúdo |
|---|---|
| `catalog-v2.json` | `gabriel-catalog` versão 2: os 37 exercícios da v1 (IDs, equipamento, tier, `reviewState`, `riskFlags` e gates inalterados) + 13 variantes novas da ficha. Nenhum ID existente foi reaproveitado com outro equipamento. |
| `blocks-ficha-abcd.json` | `gabriel-blocks-ficha-abcd` v1 com `bl.ficha-a`…`bl.ficha-d`. Blocos com item que exige liberação trazem `requiresAuthorizationId` e `blockedReasons: ["requires-authorization:<id>"]`. |
| `routine-ficha-abcd.json` | `routine.ficha-abcd` v1, `status: approved-by-user`, `publicationState: not-published`, grade fixa de 7 dias que se repete semanalmente. |
| `safety-v2.json` | Cópia da política conservadora (gates, constraints, governance, histórico de luxações) + bloco `authorizations`. |

## Autorização

`auth.ficha-abcd-2026-09-14` registra a **liberação relatada pelo usuário** (não prova independente),
com a fala literal e a data de 2026-09-14 09:19 (-03:00). Regras mantidas:

- `evidence.professionalVerified` e `independentProofOnFile` são `false`; o gerador recusa se alguém marcar `true`.
- Os gates continuam `locked`/`pending` e `selfReportAloneCanUnlock` continua `false`; a autorização é uma
  camada **escopada** por `routineIds` + `exerciseIds` + `gateIds`, com `globalUnlock`, `appliesToUnknownExercises`
  e `appliesToNewBlocks` em `false`.
- Histórico de ~6 luxações bilaterais permanece intacto em `constraints` e referenciado em `historyPreserved`.
- IDs liberados: `puxada-alta`, `elevacao-lateral`, `supino`, `supino-inclinado`,
  `triceps-frances`, `rotacao-externa-elastico`, `flexao-escapular-parede`.
  O francês conserva a classificação de carga acima da cabeça; o supino inclinado
  desta ficha usa máquina, sem misturar seu histórico de carga com halteres. Qualquer outro exercício restrito falha fechado.

## Geração

```sh
python3 GeoBridge/tools/generate_approved_abcd_plan.py \
  --week 2026-W38 --revision 1 \
  --authorization auth.ficha-abcd-2026-09-14 \
  --output GeoBridge/fixtures/training/generated/plan-2026-W38.r1-abcd.json

python3 -m unittest discover -s tests -p 'test_*.py'
```

Sem `--authorization` correto o gerador aborta. O gerador conservador
`generate_week_plan.py` não foi alterado e continua recusando estas fontes.

Segunda A · Pernas; terça e sexta cardio leve 20–30 min (dia de descanso com a dose no rótulo,
porque a UI ignora itens em dia de descanso); quarta B; quinta C; sábado D · Braços;
domingo recuperação com caminhada leve opcional. Sem falha, 2–3 RIR, descanso 120–180 s em
compostos e 60–90 s em isoladores. As superséries de D são denormalizadas em itens individuais com a
nota de alternância no nome, sem alterar repetições ou descanso.

Fortalecimento não é tratamento nem cura de instabilidade; o registro aqui é `user-reported`.
