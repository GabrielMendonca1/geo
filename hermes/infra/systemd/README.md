# garime-curator — units systemd versionadas

Fonte da verdade para os unit files do curador de contexto (WhatsApp/e-mail → Vault) na VM `garime`.
Até aqui esses arquivos existiam **só** em `/etc/systemd/system` na VM; qualquer rollback dependia de memória humana.

A árvore espelha 1:1 o destino:

```
garime-curator.service                 -> /etc/systemd/system/garime-curator.service
garime-curator.timer                   -> /etc/systemd/system/garime-curator.timer
garime-curator.service.d/whisper.conf  -> drop-in: binários de transcrição
```

O commit `aa7f1b6` é a **captura fiel** desses arquivos como rodavam na VM, sem nenhuma alteração junto. É a revisão-âncora de rollback: qualquer mudança posterior sai dele por `git show`.

## Arquitetura two-stage

Cada execução do serviço roda um pipeline de dois estágios com um portão entre eles:

1. **Triagem barata — Haiku (`HERMES_NANO_MODEL`)**
   `classify` roda por bucket (chat/e-mail), em paralelo, e produz *proposals*.
   `update_chat_summaries` atualiza o resumo de cada chat ativo.
2. **Portão** — `keep = [r for r in results if has_proposals(r)]`.
   Se `keep` estiver vazio, o run imprime `classifier surfaced nothing`, avança watermark e **retorna sem nunca instanciar o estágio 2**.
3. **Decisão cara — `prime-agent` sem estado**
   Uma única chamada, recebendo todos os buckets aprovados + `brain_context` + `chat_summaries` + `tasks_context`.
   Desde 10/08 a lane é hermética: `-p --no-session --no-tools --no-skills --no-context-files --no-extensions --no-prompt-templates --provider openai-codex --model gpt-5.6-luna --thinking high -- <prompt>`. O prompt é a única entrada.

O portão e a hermeticidade da lane são travados por `tests/pi_lane_contract.py` (`python3 tests/pi_lane_contract.py`).

O portão não é teórico: nos 12 runs entre 07/08 e 10/08, **3 imprimiram `classifier surfaced nothing`** e nunca chegaram ao estágio 2.

## Ingest bounded e idempotência

Cada execução abre `wa_ingest.jsonl` uma única vez. `scan_wa_jsonl()` deriva nessa passagem três visões: `new`, com tudo depois do watermark; `context`, com o histórico read-only das últimas 72h por chat ativo; e `bootstrap`, com a cauda longa usada somente para criar o primeiro resumo vivo de um chat ainda desconhecido. O arquivo de e-mail também é lido uma vez, mas só produz `new`: cada e-mail é atômico e nunca recebe replay de conversa ou resumo anterior.

Somente `new` pode originar proposals. O prompt do CLASSIFY separa explicitamente `CONTEXTO` de `MENSAGENS NOVAS`; o resumo vivo e o histórico de 72h existem apenas para resolver referências e entender o estado da conversa. O DECIDE recebe os resumos vivos dos chats de WhatsApp ativos naquele ciclo. E-mail contribui apenas com a mensagem recém-chegada e usa origem no formato `email <conta>: <remetente>/<assunto>`.

O corte de contexto é inclusivo na borda de 72h. Antes de entregar o histórico ao CLASSIFY, mensagens presentes em `new` são excluídas pela identidade estável: `id:<msg_id>` quando há ID; sem ID, `h:<sha1>` sobre timestamp, chat, remetente, push name, tipo, texto e `from_me`. Isso impede que a mesma linha seja simultaneamente contexto e fonte nova. Na borda do watermark, `boundary_msg_ids` guarda o ID normal ou essa chave hash fallback, preservando idempotência mesmo para registros sem `msg_id`.

O contexto mantém primeiro as 120 mensagens mais recentes e depois remove as mais antigas até que o texto agregado caiba em 6000 caracteres. Os defaults podem ser ajustados com `HERMES_WA_CONTEXT_LOOKBACK_HOURS`, `HERMES_WA_CONTEXT_MAX_MSGS` e `HERMES_WA_CONTEXT_MAX_CHARS`. Aumentá-los eleva diretamente o input do CLASSIFY; para operação conservadora, ajuste uma dimensão por vez e observe apenas as contagens de chats e mensagens no journal.

Enriquecimento de áudio, imagem e documento só começa para registros de `new`. O histórico não relê arquivo, não chama Vision e não retranscreve Whisper. Se uma mídia já estiver no memo em memória durante o run, o contexto pode reutilizar esse texto sem novo processamento.

## Custo: o que o log mede e o que ele não mede

**O `decide` não passa pela API HTTP.** `decide()` recebe um `httpx.AsyncClient`, mas não o usa para o modelo: resolve por `_pi_complete`, que faz `subprocess` do `prime-agent` — hoje com `--no-session`, sem sessão continuada.

`_usage_totals` só é incrementado dentro do helper httpx. Logo, o `calls=/in=/out=` que cada run imprime conta **apenas classify + summary (Haiku)** — a chamada cara do `decide` é invisível ali.

Prova no journal: em 09/08 21:00 o run logou `decided: …` (o estágio 2 rodou) com **`calls=1 in=1200 out=136`**. Uma chamada só. Nos 12 runs observados `calls` varia de 1 a 4, sempre sem o decide.

Consequência prática — essa métrica não é inútil, mas precisa ser chamada pelo nome certo:

- O que o log mede é **exatamente a parte que dobra com a cadência**: o custo fixo por run em Haiku, sobretudo `update_chat_summaries`, que roda **antes** do portão, incondicionalmente. Como métrica de "o que a cadência me custou a mais", ele serve.
- O que o log **não** mede é o Opus. Para 4 → 8 slots, o volume de proposals/dia é ~constante e o portão continua barrando runs vazios; o custo extra do decide é o contexto fixo re-pago pelas chamadas adicionais que passem no portão.

**O driver de custo dominante era a sessão continuada — resolvido em 10/08.** O `-c` apontava para um único arquivo que só crescia: `/mnt/garime/pi/prime-sessions/curator/019fdd88-….jsonl` chegou a **138 KB / 34 linhas**, acumulado desde a criação, e cada `decide` re-enviava esse transcript inteiro. O input por chamada crescia monotonicamente com o histórico, não com o número de slots.

Com `--no-session` o input por chamada volta a ser função só do prompt (que já era autocontido: injeta `brain_context` + `chat_summaries` + `tasks_context` + as propostas inteiras a cada chamada). A sessão continuada não carregava função nenhuma — só custo, latência e contaminação de decisões velhas. O `.jsonl` órfão é lixo morto: apagar é **manual**, depois do soak, nunca automático.

Como medir de verdade:

```
journalctl -u garime-curator.service --since "7 days ago" | grep -E "calls=|surfaced nothing"   # Haiku + taxa do portão
ls -l /mnt/garime/pi/prime-sessions/curator/*.jsonl                                            # crescimento do contexto do decide
```

Baseline de 7d antes × 7d depois nas **duas** medidas. Alarme se o Haiku/dia passar de 2×, ou se o `.jsonl` acelerar o crescimento. Se ele virar o gargalo, a correção é rotacionar a sessão — não mexer na cadência.

## Cadência e completude

`OnCalendar=*-*-* 00,03,06,09,12,15,18,21:00:00 America/Sao_Paulo`, `Persistent=true`.

- **Cadência não afeta completude.** O anti-gap real é o watermark persistido (`STATE_PATH`, `last_processed_ts`): somente a visão `new` de `scan_wa_jsonl()` pode gerar proposals, e o watermark só avança quando CLASSIFY, atualização dos resumos e DECIDE terminam com sucesso. Falha no meio → watermark parado → o próximo ciclo reprocessa a mesma janela. `boundary_msg_ids` resolve empates de timestamp; duplicatas posteriores são absorvidas por `dedup_skips` no persist. Mudar 4 → 8 slots muda **latência**, nunca cobertura.
- **Overlap não acontece.** `Type=oneshot` sem `RemainAfterExit`: enquanto o `ExecStart` roda a unit fica em `activating`, e um elapse do timer nesse intervalo **funde** com o job em execução — systemd não cria segunda instância. Runs históricos duram 2–13s contra 3h de espaçamento.
- **DST:** America/Sao_Paulo não observa horário de verão desde 2019; com timezone explícita não há hora pulada ou duplicada.

### Ressalvas operacionais

1. **`Persistent=true` × LUKS manual.** Depois de um reboot, o catch-up pode disparar antes de alguém rodar `unlock.sh`. Aí `ExecStartPre=mountpoint -q /mnt/garime` falha e `OnFailure=garime-alert@` dispara. Isso é fail-fast por design — trate o alerta como lembrete de unlock, não como bug.
2. **Reiniciar o timer no meio do dia pode disparar um run imediato.** Se o último elapse do calendário novo for posterior ao stamp persistido, `Persistent=true` faz catch-up na hora. É benigno e esperado durante o deploy.
3. **O slot de 00:00 muda a bucketização do digest diário.** Mensagens de ~21h–00h passam a poder cair no `date_iso` do dia seguinte. É drift de bucket, não perda.
4. **Pressão no OAuth.** Dobrar a cadência dobra a frequência de refresh do token do curator. Falha de auth (401/403) faz o run retornar 1 → alerta; recuperação é re-semear via `setup-token`.

## Pin de modelo: no código, não em drop-in

Um drop-in `models.conf` fixando `HERMES_NANO_MODEL`/`HERMES_WA_DECIDE_MODEL`/`HERMES_WA_DECIDE_EFFORT` foi **rejeitado** — dois pins eram no-op e o terceiro era uma regressão silenciosa, porque `_pi_complete` só passava `--model` se a var estivesse setada. Com ela unset, quem resolvia era o `prime-agent`: **`claude-opus-4-7`** nas 10 chamadas da sessão viva.

Em 10/08 o pin virou **decisão consciente no código**, que é a condição que a versão anterior desta seção exigia:

| var | default | resolvido por |
|---|---|---|
| `HERMES_WA_DECIDE_PROVIDER` | `openai-codex` | `_decide_provider()` |
| `HERMES_WA_DECIDE_MODEL` | `gpt-5.6-luna` | `_decide_model()` |
| `HERMES_WA_DECIDE_EFFORT` | `high` | `_decide_effort()` |

Os três são **incondicionais** no argv — não existe mais o ramo `if model:`, então não existe mais a divergência entre "o que o env diz" e "o que o `prime-agent` resolve". `_decide_model()` deixou de ser código morto: era ele o call site que faltava. Cada var é independente; setar uma sozinha usa o default das outras.

O par configurado no código é `openai-codex gpt-5.6-luna`. **O `Environment` do service segue sem nenhuma `HERMES_WA_DECIDE_*`** — o default do código é quem manda, e é de propósito: o pin fica versionado no repo, não espalhado num drop-in.

Continua valendo: nenhum drop-in novo entra sem estar em `UNITS`.

`install.sh` agora **falha** se aparecer qualquer drop-in em `garime-curator.service.d/` que não esteja declarado em `UNITS`: todo drop-in altera o `Environment` do service, então nenhum entra por acidente.

## Deploy

**Não há checkout deste repo na VM** (`find / -name .git` só acha whisper.cpp, `brain` e backups). Então o deploy tem duas etapas: levar os arquivos, depois rodar.

Do Mac, a partir do repo:

```
rsync -a --delete hermes/infra/systemd/ garime:/tmp/garime-units/
ssh garime '/tmp/garime-units/install.sh --check'   # só verificação estática, não escreve nada
ssh garime 'sudo /tmp/garime-units/install.sh'      # instala, daemon-reload, restart do timer
ssh garime 'rm -rf /tmp/garime-units'
```

O `--delete` importa: garante que o staging não carregue um drop-in órfão de uma execução anterior — que o guard de `UNITS` rejeitaria, mas melhor não chegar lá.

O script é idempotente: compara cada arquivo com o destino via `cmp` e só faz `daemon-reload`/restart se algo mudou de fato. Rodar 2× seguidas na segunda vez imprime `ja identico` em tudo e `nada mudou; daemon-reload dispensado`.

### O script nunca faz deploy de código

`/opt/garime-curator/context_scraping.py` **divergiu** do repo por meses (paths `/mnt/garime` em vez de `~/.hermes`, ingest de e-mail, campo `confidence` em tasks). Em 10/08 o arquivo vivo foi copiado da VM para `hermes/scripts/context_scraping.py` e **o repo voltou a ser a referência** — a lane DECIDE já foi alterada só no repo, e a VM está atrás dessa mudança até alguém fazer o deploy manual.

Duas dependências de runtime continuam **só na VM**, fora do git: `email_ingest.py` (produtor do `email_ingest.jsonl`; não é importado pelo script) e `plugins/geo-tools/` (`geo_write`, `tasks_fs` — importados no topo). Reconciliar essas duas é trabalho separado; enquanto isso, `hermes/` não é auto-suficiente para rodar.

Por isso `install.sh` opera sobre uma allowlist explícita de unit files e aborta se qualquer arquivo fora dela (em especial `.py`) aparecer no payload. Reconciliar o script Python é um trabalho separado, feito conscientemente — nunca um efeito colateral de mexer no timer.

### Dependência não versionada

`garime-alert@.service` (referenciada por `OnFailure`) existe só na VM e depende de `/opt/garime-curator/alert.sh`, que não está no repo. Versionar a unit sem o script daria uma falsa sensação de completude, então ficou de fora de propósito. Se `alert.sh` for versionado um dia, traga a unit junto.

## Verificação

Após o deploy:

```
systemctl show garime-curator.service -p Environment    # HOME + as 3 do whisper; nenhuma var de modelo
systemctl list-timers garime-curator.timer              # NEXT no próximo múltiplo de 3h em -03
systemd-analyze calendar --iterations=9 "*-*-* 00,03,06,09,12,15,18,21:00:00 America/Sao_Paulo"
```

Smoke funcional sem sujar o vault: `context_scraping.py --dry-run` roda o pipeline inteiro sobre mensagens reais (classify → portão → decide), imprime o JSON decidido e **não** persiste, **não** avança watermark, **não** salva summaries. Rode como `biel` com o env reproduzido de `systemctl show -p Environment`. Custo assumido: o dry-run gasta tokens e o run agendado seguinte reprocessa a mesma janela (watermark parado) — rode logo após um sucesso agendado para encurtar essa janela.

## Rollback

Só o `.timer` muda. A âncora é o commit `aa7f1b6`. Do Mac, a partir do repo:

```
git show aa7f1b6:hermes/infra/systemd/garime-curator.timer | ssh garime 'sudo tee /etc/systemd/system/garime-curator.timer >/dev/null'
ssh garime 'sudo systemctl daemon-reload && sudo systemctl restart garime-curator.timer'
ssh garime 'systemctl list-timers garime-curator.timer --no-pager'
```

Volta para `06,12,17,21`. Nenhuma limpeza de estado: o watermark é indiferente à cadência, então não há reprocessamento nem gap ao reverter.
