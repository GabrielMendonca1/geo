# STATUS — spirit (garime)

> atualizado: 2026-08-24

## Todo
- [ ] escrever o plano da transição Geo → garime (infra e nomenclatura)
- [ ] colar os 2 tokens novos em Ajustes do app (sem eles o app fica em tokenMissing)
- [ ] abrir a porta 22 do `garime` no console da OCI (hoje não há rota de fuga fora do tailnet)
- [ ] rodar `GarimeHub/migrate.sh` e conceder os grants de TCC do Garime Hub (microfone, acessibilidade, automação Finder)
- [ ] F2 do lifecycle de entradas (loop de clusters na sessão Geo Vault Cleaning)
- [ ] F3 e F4 do lifecycle de entradas
- [ ] decidir se o pipeline zap→Vault volta na VM (hermes local aposentado)
- [ ] corrigir `spans()` O(n²) no chat (hoje só protegido pelo teto de 2000 chars)
- [ ] preencher `DEVELOPMENT_TEAM` no `gen_project.rb` (1 linha)
- [ ] atualizar CONTRACT.md/plist do bridge: dizem que ele mora no Mac, roda na VM
- [ ] corrigir a nota de Saúde que usa `type: reference` (fora do vocabulário do geo_write)
- [ ] reconciliar as 4 divergências de slugs front/back vs `BodyPaths.swift`
- [ ] tratar workflow interrompido que fica `started` sem `result` e conta como rodando pra sempre
- [ ] endurecer verbos de leitura do /term: `session=` malformado ainda cai na sessão default
- [ ] ler `/proc/<pid>/cwd` para transcript de processos prime fora do tmux
- [ ] decidir o destino do histórico congelado de `Captures/` na VM
- [x] GarimeCapture aposentado (2026-10-14): prints ficam onde o macOS salva, `~/Pictures/SCREENSHOT`; estado, binário e agentes em `~/Library/Application Support/Garime/Backups/GarimeCapture/20261014-133339/`
- [ ] decidir a aposentadoria total da VM antiga `garime-bridge` na OCI
- [ ] investigar por que o alerta de outage prolongado do whatsapp-ingest não disparou
- [ ] podar `task_archive/` e corrigir repeat null-target no `context_scraping`
- [ ] retomar a Fase 3 do terminal (chat com o pi + push de fim de task)
- [ ] nits de UI: fonte do card bridge, locale EN no DatePicker

## Feito
- [x] código morto removido: endpoint `/term/preview` sem chamador e `settingsToolbar()` sem referências; contrato atualizado (2026-08-30)
- [x] Saúde v2: catálogo real (37 exercícios/20 blocos), safety gates, plano semanal como fonte principal, logs plan-primary retrocompatíveis; bridge implantado, W35 publicada e app instalado no iPhone (2026-08-24)
- [x] GarimeWhisper promovido a hub único de menu bar — reunião/call, insomnia nativo (Capsomnia removido), observador do GarimeCapture, tasks do Vault e todos por projeto; instalado e vivo (2026-08-17)
- [x] Garime Whisper: ditado nativo na menu bar instalado e vivo (2026-08-07)
- [x] bridge da VM enxerga sessões `prime-agent` na lista de agentes (2026-08-06)
- [x] Leva AH: agente operável pelo celular (perguntar, responder, interromper, iniciar) (2026-08-06)
- [x] limpeza do repo 1.7G → 879M e tailscale atualizado nas 2 VMs (2026-08-06)
- [x] Leva AG: home reestruturada, chat live e markdown renderizado (2026-08-05)
- [x] auditoria de infra: ControlMaster no ssh e hardening de bridge/app (2026-08-05)
- [x] Claude Code instalado e autenticado na VM garime (2026-08-05)
- [x] aba Saúde no app: protocolo do vault, mapa muscular e cargas (2026-08-04)
- [x] Liquid Glass no app inteiro e lista de agentes reais via herdr (2026-08-04)
- [x] bridge migrado para a VM garime em https://garime.tail091418.ts.net (2026-08-03)
