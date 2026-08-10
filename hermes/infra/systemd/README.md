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
3. **Decisão cara — Opus, via `prime-agent`**
   Uma única chamada, recebendo todos os buckets aprovados + `brain_context` + `chat_summaries` + `tasks_context`.

O portão não é teórico: nos 12 runs entre 07/08 e 10/08, **3 imprimiram `classifier surfaced nothing`** e nunca chegaram ao estágio 2.

## Custo: o que o log mede e o que ele não mede

**O `decide` não passa pela API HTTP.** `decide()` recebe um `httpx.AsyncClient`, mas não o usa para o modelo: resolve por `_pi_complete`, que faz `subprocess` do `prime-agent` com `-c` (sessão continuada).

`_usage_totals` só é incrementado dentro do helper httpx. Logo, o `calls=/in=/out=` que cada run imprime conta **apenas classify + summary (Haiku)** — a chamada cara do `decide` é invisível ali.

Prova no journal: em 09/08 21:00 o run logou `decided: …` (o estágio 2 rodou) com **`calls=1 in=1200 out=136`**. Uma chamada só. Nos 12 runs observados `calls` varia de 1 a 4, sempre sem o decide.

Consequência prática — essa métrica não é inútil, mas precisa ser chamada pelo nome certo:

- O que o log mede é **exatamente a parte que dobra com a cadência**: o custo fixo por run em Haiku, sobretudo `update_chat_summaries`, que roda **antes** do portão, incondicionalmente. Como métrica de "o que a cadência me custou a mais", ele serve.
- O que o log **não** mede é o Opus. Para 4 → 8 slots, o volume de proposals/dia é ~constante e o portão continua barrando runs vazios; o custo extra do decide é o contexto fixo re-pago pelas chamadas adicionais que passem no portão.

**O driver de custo dominante não é a cadência — é a sessão continuada.** O `-c` aponta para um único arquivo que só cresce: hoje `/mnt/garime/pi/prime-sessions/curator/019fdd88-….jsonl` está em **138 KB / 34 linhas**, acumulado desde a criação. Cada `decide` re-envia esse transcript inteiro. O input por chamada cresce monotonicamente com o histórico, não com o número de slots — e dobrar a cadência dobra a taxa com que ele engorda.

Como medir de verdade:

```
journalctl -u garime-curator.service --since "7 days ago" | grep -E "calls=|surfaced nothing"   # Haiku + taxa do portão
ls -l /mnt/garime/pi/prime-sessions/curator/*.jsonl                                            # crescimento do contexto do decide
```

Baseline de 7d antes × 7d depois nas **duas** medidas. Alarme se o Haiku/dia passar de 2×, ou se o `.jsonl` acelerar o crescimento. Se ele virar o gargalo, a correção é rotacionar a sessão — não mexer na cadência.

## Cadência e completude

`OnCalendar=*-*-* 00,03,06,09,12,15,18,21:00:00 America/Sao_Paulo`, `Persistent=true`.

- **Cadência não afeta completude.** O anti-gap real é o watermark persistido (`STATE_PATH`, `last_processed_ts`): `read_window()` só devolve mensagens mais novas que ele, e o watermark só avança quando `advance_ok and decide_ok`. Falha no meio → watermark parado → o próximo ciclo reprocessa a mesma janela. Semântica at-least-once; duplicatas são absorvidas por `dedup_skips` no persist. Mudar 4 → 8 slots muda **latência**, nunca cobertura.
- **Overlap não acontece.** `Type=oneshot` sem `RemainAfterExit`: enquanto o `ExecStart` roda a unit fica em `activating`, e um elapse do timer nesse intervalo **funde** com o job em execução — systemd não cria segunda instância. Runs históricos duram 2–13s contra 3h de espaçamento.
- **DST:** America/Sao_Paulo não observa horário de verão desde 2019; com timezone explícita não há hora pulada ou duplicada.

### Ressalvas operacionais

1. **`Persistent=true` × LUKS manual.** Depois de um reboot, o catch-up pode disparar antes de alguém rodar `unlock.sh`. Aí `ExecStartPre=mountpoint -q /mnt/garime` falha e `OnFailure=garime-alert@` dispara. Isso é fail-fast por design — trate o alerta como lembrete de unlock, não como bug.
2. **Reiniciar o timer no meio do dia pode disparar um run imediato.** Se o último elapse do calendário novo for posterior ao stamp persistido, `Persistent=true` faz catch-up na hora. É benigno e esperado durante o deploy.
3. **O slot de 00:00 muda a bucketização do digest diário.** Mensagens de ~21h–00h passam a poder cair no `date_iso` do dia seguinte. É drift de bucket, não perda.
4. **Pressão no OAuth.** Dobrar a cadência dobra a frequência de refresh do token do curator. Falha de auth (401/403) faz o run retornar 1 → alerta; recuperação é re-semear via `setup-token`.

## Por que não há pin de modelos

Uma versão anterior desta mudança trazia um drop-in `models.conf` fixando `HERMES_NANO_MODEL`, `HERMES_WA_DECIDE_MODEL` e `HERMES_WA_DECIDE_EFFORT`. **Foi removido**, e o motivo vale documentar para ninguém reintroduzir:

- `HERMES_NANO_MODEL` — `_nano_model()` (L96) é env-first com fallback `claude-haiku-4-5`. Pin idêntico ao fallback: **no-op**.
- `HERMES_WA_DECIDE_EFFORT` — `_decide_effort()` (L108) já é aplicado incondicionalmente em `_pi_complete`. Pin idêntico ao fallback: **no-op**.
- `HERMES_WA_DECIDE_MODEL` — aqui está a armadilha. `_decide_model()` (L100), que devolve `claude-opus-4-8`, é **código morto: zero call sites**. O consumidor real é `_pi_complete` L335, e ele é *condicional*:

  ```python
  model = os.environ.get("HERMES_WA_DECIDE_MODEL")
  if model: argv += ["--model", model]
  ```

  Com a var **unset** (estado atual: `systemctl show -p Environment` lista só `HOME` + as 3 do whisper), `--model` nunca é passado e quem resolve é o `prime-agent` — que na sessão viva do curator resolveu **`claude-opus-4-7`** nas 10 chamadas registradas.

Ou seja: instalar o pin **trocaria** o modelo do decide de 4-7 para 4-8 em produção, 8×/dia, sob um comentário que dizia "não muda comportamento nenhum". Dos três pins, os dois inertes não valiam nada e o único ativo era uma regressão silenciosa. Um drop-in assim não é pin, é passivo — e era escopo alheio a uma mudança de cadência.

Se um pin for desejado um dia, ele tem que ser uma decisão consciente sobre **qual** modelo, validada contra o que o `prime-agent` resolve hoje — não uma cópia dos fallbacks do código.

`install.sh` agora **falha** se aparecer qualquer drop-in em `garime-curator.service.d/` que não esteja declarado em `UNITS`: todo drop-in altera o `Environment` do service, então nenhum entra por acidente.

## Deploy

Rode **na VM**, a partir de um checkout do repo:

```
hermes/infra/systemd/install.sh --check    # só verificação estática, não escreve nada
hermes/infra/systemd/install.sh            # instala, daemon-reload, restart do timer
```

O script é idempotente: compara cada arquivo com o destino via `cmp` e só faz `daemon-reload`/restart se algo mudou de fato.

### O script nunca faz deploy de código

`/opt/garime-curator/context_scraping.py` **divergiu** do fonte no repo (`hermes/scripts/context_scraping.py`) em ~790 linhas — paths `/mnt/garime` em vez de `~/.hermes`, ingest de e-mail, campo `confidence` em tasks, entre outros. **Produção é a referência, não o repo.**

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

Só o `.timer` muda. A âncora é o commit `aa7f1b6`:

```
git show aa7f1b6:hermes/infra/systemd/garime-curator.timer | sudo tee /etc/systemd/system/garime-curator.timer
sudo systemctl daemon-reload
sudo systemctl restart garime-curator.timer
systemctl list-timers garime-curator.timer
```

Volta para `06,12,17,21`. Nenhuma limpeza de estado: o watermark é indiferente à cadência, então não há reprocessamento nem gap ao reverter.
