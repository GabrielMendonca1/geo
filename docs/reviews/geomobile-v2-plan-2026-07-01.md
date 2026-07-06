# GeoMobile v2 — Plano consolidado (2026-07-01)

Origem: 4 planejadores Opus read-only (g-swarm fan-out), consolidados. Execução prevista: 1 workflow ultracode por aba, **sequenciais** (ver Costuras).

## Decisão de transporte: MANTER TAILSCALE

- Custo de migração zero; já smoke-green ponta a ponta.
- Alternativas rejeitadas: WireGuard puro (sem endpoint estável p/ laptop atrás de CGNAT), Cloudflare Tunnel/Access (expõe hostname público de vault privado + timeout ~100s corta SSE longo), relay na VM ubuntu-arca-1 (hop termina em texto claro numa VM da empresa — privacidade), Tailscale Funnel (público), Bonjour/LAN fallback (Tailscale já vai direto na mesma LAN — duplica caminho existente).
- HTTPS self-signed na tailnet = **teatro** (WireGuard já criptografa ponta-a-ponta). Única variante útil se um dia precisar: `tailscale serve` (MagicDNS + cert LE real, tailnet-only) — nice-to-have, não fazer agora.
- Fato load-bearing p/ tudo: ATS do iOS isenta IP-literal — HTTP puro funciona SÓ porque a URL é IP. Hostname DNS exigiria https. `isAllowedBaseURL` (BridgeConfig.swift:20-26) já aceita https de qualquer host (migração futura prevista).
- Ações baratas recomendadas:
  1. ACL do Tailscale travando a porta 8643 só pro nó do iPhone (config no admin, zero código) — ação manual do Gabriel.
  2. Resiliência no app: diferenciar connection-refused/timeout ("Mac dormindo") de 401 ("token errado"); badge de status via `/health`. Pequeno, cross-tab (BridgeClient/Settings) — fazer inline após os 3 workflows, fora deles.

## Costuras entre os planos (regras de execução)

1. `geobridge.py` + `CONTRACT.md` são tocados por Tasks (`POST /tasks`) e Terminal (`/term/*`) → **workflows sequenciais, nunca paralelos**. Bump do CONTRACT: Tasks v1→2, Terminal v2→3.
2. `project.pbxproj` é GERADO por `gen_project.rb` (rm_rf + recria). Toda mudança de build setting/dependência SPM vai no `gen_project.rb` — corrige o plano do Chat, que propunha editar pbxproj direto (INFOPLIST_KEY_UIBackgroundModes, deployment target) e o do Terminal já sabia (SwiftTerm via XCRemoteSwiftPackageReference no gen_project.rb).
3. `BridgeClient.swift`: Chat (cancel já existe, sem mudança provável) e Terminal (talvez streamTimeout maior) — sequencialidade resolve.
4. Ordem recomendada: **Tasks → Chat → Terminal** (menor→maior; Tasks valida o pipeline de mudança bridge+CONTRACT com o menor risco; Chat é só iOS; Terminal é a maior escalação e vai por último).
5. Cada workflow termina com: `ruby gen_project.rb` + build device verde + install no iPhone. Features de áudio (AEC/barge-in) e terminal interativo só se validam NO APARELHO — checklist manual pro Gabriel no fim de cada workflow.
6. Working tree do repo está suja com trabalho de outra feature (calendar mirror) — NUNCA git checkout/reset global; commits só se Gabriel pedir.

---

## PLANO 1 — Tasks (workflow 1)

Corte v2 (3 itens, ordem A→C→B):

**A. Agrupamento Atrasadas / Hoje / Próximas** (só iOS, custo quase zero)
- `TasksViewModel.swift`: substituir `open` por `overdue`/`today`/`upcoming` publicados. overdue = pending & `isOverdue` (TaskItem.swift:657-668, kind-aware); today = pending & !overdue & `isDateInToday(anchorDate)`; upcoming = resto. Ordenar cada bucket por anchorDate→priority (regra atual :52-55). `completedToday` mantém. `isEmpty` (VM:17) considera os 3.
- `TasksView.swift`: 3 `Section` (Atrasadas em vermelho/Hoje/Próximas), ocultar vazias, manter swipe-complete (:44-51) e disclosure de concluídas (:54-65).
- Relação com aba Hoje: NÃO deduplicar; papéis explícitos (Hoje = agenda time-boxed; Tasks = backlog priorizado; overlap estilo Apple Reminders é ok).

**C. Reopen por swipe** (backend já existe: `BridgeTasksRepository.swift:44-47`, `geobridge.py:106-108` — só nunca ligado na UI)
- VM: `reopen(_:)` espelhando `complete()` (:30-47), otimista com rollback.
- View: `swipeActions(edge: .leading)` nas linhas de "Completed Today" → "Reopen" (arrow.uturn.backward).

**B. Criar task do celular** (bridge + iOS; decisão fixada: iOS gera id UUID maiúsculo + JSON completo; bridge só valida e grava — dumb pipe)
- `geobridge.py`: `do_POST` ganha `elif path == "/tasks": self._create_task()`. Validar: dict com `id` (regex valid_id :37-38), `title` str não vazia, `body.kind` ∈ {task,event,habit,milestone}, `createdAt`; 400 se inválido. `O_CREAT|O_EXCL` → 409 `task_exists` se existir. Gravação atômica tempfile+fsync+os.replace (reaproveitar bloco do `_mutate_task` :160-171). 201 com bytes gravados.
- `CONTRACT.md`: bump v1→2; revisar princípio 4 (:12); seção `POST /tasks` (shape :59-77; iOS NÃO envia `externalEKEventID` — o Mac preenche via mirror). Datas ISO-8601 segundos com Z, SEM fração (decoder .iso8601 do Mac falha com fração — TasksStore.swift:394,494).
- `BridgeTasksRepository.swift`: implementar `create(_:)` (:53-55) — TaskItem de TaskDraft, encoder iso8601 puro (adicionar `iso8601Encoder` no BridgeClient espelhando :39-43), `postData("/tasks")`.
- iOS UI: botão "+" no toolbar; sheet título+DatePicker(due)+Picker(priority); v2 fixa kind=task, `reminders = [.atTime()]`; otimista com rollback.
- Caminho fim-a-fim (fato verificado): bridge grava `<id>.json` → FileWatcher do Geo.app → `TasksStore.handleExternalChanges` (TasksStore.swift:469-518) → `scheduleMirror` → EventKit cria evento no Apple Calendar DE GRAÇA. Grace period 0.8s não suprime escritas do bridge (CONTRACT.md:166).
- FORA (justificado): cache offline (fila offline = explosão de escopo, sem dor real), notificações locais (duplica alertas do mirror Calendar), auto-polling (bateria; no máximo reload em scenePhase .active), filtros por kind, editar/deletar (criar cobre ~80%).
- Verificação: 106 tasks agrupam certo; task criada no celular aparece no Geo.app ~1s e no Apple Calendar; refresh traz `externalEKEventID`; completar 2× idempotente; off-tailnet = erro claro sem crash.

---

## PLANO 2 — Chat voice-first (workflow 2)

Design fechado:
- **Modo Conversa** (hands-free por turno): orbe toca → ciclo `ouvindo → silêncio (~0.8-1.2s, VAD por RMS no tap + parciais) auto-envia → pensando → falando → ouvindo…`. Hold-to-talk atual vira fallback. Wake-word descartado (sem API iOS viável).
- **STT**: manter `SFSpeechRecognizer` pt-BR com `requiresOnDeviceRecognition = true` (checar `supportsOnDeviceRecognition`; degradar pra rede com aviso). Reciclar recognizer por turno. SpeechAnalyzer (iOS 26+) = fast-follow atrás de @available, NÃO agora (exigiria target 17→26).
- **TTS streaming por sentença** (maior ganho de latência): buffer de deltas → fim de sentença (`.!?\n` ou ~160 chars) → fila do AVSpeechSynthesizer. Voz pt-BR enhanced/premium quando instalada. Hoje TTS só dispara pós-completed (ChatViewModel.swift:57,60) = latência da resposta inteira.
- **IA decide voz vs texto** em 2 camadas: (1) heurística cliente — code fence/tabela/lista longa/links/comprimento → texto (com frase-guia opcional "te mandei no texto"); curto conversacional → voz+texto. (2) opcional fase 2: marcador `⟦voice⟧`/`⟦text⟧` no início da resposta, removido do stream, + campo `voice: true` no body (bridge repassa — geobridge.py:315 hoje só encaminha message; CONTRACT.md:138-141 ganha campo opcional) + instrução no hermes/SOUL. Camada 1 não toca bridge.
- **Barge-in full-duplex com AEC**: mic aberto durante TTS via voice-processing (`.voiceChat`/setVoiceProcessingEnabled); fala sustentada → stopSpeaking(.immediate) + limpa fila + cancela SSE (cancel já existe — BridgeClient.swift:105) + novo turno. Gate por energia sustentada. Half-duplex descartado (pedido explícito). **Limitação conhecida**: sem cancel server-side — hermes persiste o turno inteiro na SessionDB mesmo interrompido.
- **Máquina de estados** `idle/listening/thinking/speaking` com orbe animado; usar `run.started`/`message.started`/`tool.progress` (hoje ignorados — ChatViewModel.swift:67) pro estado "pensando/consultando…".
- **Áudio**: novo AudioSessionManager — `.playAndRecord` + `.voiceChat` (AEC), `.duckOthers, .allowBluetooth, .allowBluetoothA2DP`, remover `.defaultToSpeaker` com AirPods; tratar interruption + routeChange. Abrir mão de `.measurement` (briga com AEC). AirPods = rota HFP degrada STT/TTS (tradeoff registrado).
- **Background/tela bloqueada = stretch**: `INFOPLIST_KEY_UIBackgroundModes=audio` via **gen_project.rb** (NÃO pbxproj direto — é gerado) + MPNowPlaying/RemoteCommand; ASR em background é restrito pela Apple — alvo primário foreground+AirPods.

Arquivos novos (Features/Chat/): AudioSessionManager, SpeechRecognitionService, SpeechSynthesisService (fila por sentença), ResponseModality (classificador+marcador), VoiceSessionController (máquina de estados, absorve SpeechController de ChatView.swift:187-328), ConversationOrbView/VoiceInputBar.
Tocar: ChatView.swift (input voice-first, remover SpeechController), ChatViewModel.swift (expor deltas pro TTS, consumir run/tool events, cancel do stream).
Bridge: NENHUMA mudança no core (fase 2 opcional: campo voice).
Ordem: refactor sem mudar comportamento → sessão AEC → TTS por sentença → ResponseModality → VAD/loop hands-free → barge-in → UI orbe → (opc) background → (opc) voice flag.
Verificação no aparelho (só lá): TTS falando alto NÃO se auto-dispara; barge-in para e captura só a fala do usuário; modo avião prova STT on-device; time-to-first-audio na 1ª sentença; marcador nunca aparece na tela; AirPods conectar/desconectar no meio do turno.

---

## PLANO 3 — Agents = terminal real (workflow 3)

Design fechado:
- **Mac**: tmux como camada durável (sessão fixa `mobile`); cada conexão SSE = attach efêmero via `pty.fork()` + `exec tmux -u new-session -A -s mobile`. Sobrevive a lock/troca de aba/app morto/restart do bridge. tmux 3.5a já em /opt/homebrew/bin (caminho ABSOLUTO no env — PATH do launchd é mínimo). Loop select 0.5s → chunk → base64 → `data:`; keepalive 15s (padrão geobridge.py:277-280); EIO → `event: done`. Input: registry global session→master_fd com threading.Lock; `POST /term/input` = os.write de bytes crus base64 (ctrl-c 0x03, setas ESC[A-D fluem). Resize: `POST /term/resize` → ioctl TIOCSWINSZ.
- **Protocolo: SSE+POST, NÃO WebSocket** — geobridge é stdlib pura (WS na mão = ~150-250 linhas frágeis de RFC 6455) e `BridgeClient.stream` (BridgeClient.swift:65-107, aceita POST+body) é reusado verbatim. Custo honesto: POST por lote de teclas; segurar tecla fica lento (aceitável v1; WS só se latência doer, v2).
- **iOS: SwiftTerm** (MIT, SPM) via `XCRemoteSwiftPackageReference` **no gen_project.rb** (espelhar bloco GeoCore :46-57 — regen apaga o que estiver só no Xcode). TerminalView = UIViewRepresentable; saída → `terminal.feed`, input delegate → POST, sizeChanged → resize. Render ANSI próprio descartado (grid VT100 completo = semanas, sutilmente errado; EventRow atual é append de linha, não serve). Accessory bar: Esc/Tab/Ctrl(modificador)/setas/`|`/`-`/`~`.
- **UI**: botão/NavigationLink "Terminal" na toolbar de AgentsView (:19) → TerminalView. Espelho read-only de dispatches fica como está.
- **Segurança (escalação categórica — shell arbitrário como biel via tailnet)**: (1) segundo token dedicado `~/.hermes/geobridge.term.token` (GEO_BRIDGE_TERM_TOKEN_FILE; install.sh espelha :12-15) — revogável isolado, defesa-em-profundidade; (2) `GEO_TERM_ENABLED=0` por default, `/term/*` = 404 até ligar no plist; (3) bind tailnet-only inalterado; (4) NUNCA logar teclas (input só no corpo do POST; log só open/close/resize); (5) idle-detach do attach (sessão tmux sobrevive).
- Env novos: GEO_TERM_ENABLED, GEO_TERM_TMUX, GEO_TERM_SHELL, GEO_TERM_SESSION, GEO_BRIDGE_TERM_TOKEN_FILE. Plist ganha os env; CONTRACT.md bump + seção Terminal + carve-out do princípio 4 com aviso de blast radius.
- Corte v1: sessão única `mobile`, 3 endpoints, gate por flag, segundo token (ou token atual documentado se time-boxed), SwiftTerm + accessory bar + resize. v2: seletor de sessões, copy-mode/paste, fonte/tema, WS, idle-detach configurável, token na Settings UI.
- Ordem: bridge+plist+install+CONTRACT (validar por curl na tailnet ANTES do iOS) → gen_project.rb SwiftTerm → TerminalView/VM+accessory → (v2) token UI.
- Riscos: streamTimeout 90s (BridgeClient.swift:34) vs SSE ocioso — keepalive 15s cobre, verificar; vim/htop provam emulador; persistência = loop `while true; do date; sleep 1; done` sobrevive a (a) troca de tab (b) lock (c) app morto (d) kickstart do bridge; log sem bytes digitados.

---

## Pós-workflows (inline, fora deles)

- Resiliência do app: erro connection-refused/timeout ≠ 401; badge de status via /health (BridgeClient/Settings).
- Gabriel (manual): ACL do Tailscale (porta 8643 só pro nó do iPhone).
- STATUS.md do repo: atualizar ao fim de cada workflow.
