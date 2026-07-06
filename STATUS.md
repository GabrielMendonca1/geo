# STATUS — Mega refactor do Brain pane

Plano: `~/.claude/plans/greedy-sprouting-oasis.md`
Objetivo: brain pane → navegador estilo Obsidian/Bear (sidebar de notas · editor com abas · grafo local).

## Estado atual
- **Implementação completa (F0+F1+F2+F3)** — verificada por compilação + testes. **Falta só o smoke visual** (precisa de sessão interativa; este background job não tem acesso ao window server).

## Fases
- [x] **F0** Monólito (908L) quebrado em `Features/Brains/{Data,Domain,UI,Support}`. Sem mudança de comportamento. **BUILD SUCCEEDED**.
- [x] **F1+F2** Shell de 3 painéis (`ThreeColumnSplit`, divisórias arrastáveis, larguras em @AppStorage) + sidebar (busca/lista/vault switcher) + editor com abas (`PaneTabBar` + `ExternalFileEditorModel`+`BlockListView`; abas vivas preservam undo/cursor) + grafo local com aba (`localSubgraph` 1 salto; tap no nó abre a nota). Clique em `[[wikilink]]` navega entre notas. Substitui "abrir no Finder".
- [x] **F3** Status bar (backlinks·words), criar nota (`createNote`), entrada de Sources/ingest (ícone tray na sidebar → `BrainSourcesSheet`), empty states. Testes unitários novos (`localSubgraph`/`backlinkCount`/`nodeID`/`createNote`). **TEST SUCCEEDED**.
  - *Deferido*: linha de `#tag` pills sob a aba — o editor já renderiza `#tags` inline; linha separada duplicaria. Decidir após ver na tela.

## Verificação
- ✅ `xcodebuild build` Debug (`CODE_SIGNING_ALLOWED=NO`) e Release (`CODE_SIGN_IDENTITY=-`) → **BUILD SUCCEEDED**.
- ✅ `xcodebuild test -only-testing:GeoTests/BrainsTests` (ad-hoc + `ENABLE_DEBUG_DYLIB=NO`) → **TEST SUCCEEDED**.
- ⏳ **Smoke visual pendente** — sem captura de tela no background job (`screencapture` negado / sem window server). Geo está RODANDO (instância diária), então **não sobrescrevi `/Applications`**.

## Correção pós-review (Gabriel)
- [x] **Sources re-promovido**: o fluxo de adicionar fontes (arquivos/links → agente `brain.py` constrói as notas) estava num ícone discreto. Agora: botão **"Sources"** (com contador) no topo da sidebar + CTA **"Add sources"** no estado de cérebro vazio. **BUILD SUCCEEDED**, instalado e rodando.

## Plano B — Editor com abas no NodesPane (+ janela destacada) · g-triad
Plano aprovado: `~/.claude/plans/greedy-sprouting-oasis.md`. Subagent workflow bloqueado por **limite semanal** (reseta 19h Bahia) → implementando direto no loop principal, fatiado e buildando a cada passo.
- [x] **F1** `PaneTabBar`/`ResizableSplit` movidos p/ `Shared/DesignSystem/Panes/` + fix #7 (commit-on-end). BUILD verde.
- [x] **F2** Componente compartilhado `DocTabs` (`OpenDocRef`+`DocTabsModel`+`DocTabsView`) com fixes #1 (lookup O(1)), #2 (status debounced fora do render), #4 (LRU de editores); `BrainGraphCache` (#3). **Brains migrado** pro componente (`BrainEditorTabs`/`BrainWorkspaceModel` consolidados). **BUILD + TEST SUCCEEDED**, reinstalado.
- [x] **F3** `NodesPane` 3 colunas (sidebar `BlocksPane` | `DocTabsView` | `GraphView`); `BlocksPane.onOpen`→aba (cmd+click=seleção, contexto=janela); tap no grafo→aba; wikilink→aba (por título); pop-out→janela+fecha aba; backlinks via `IndexCoordinator.shared`; nova nota via `createBlock`. seed/wasSettled preservados; `leftHidden` vira editor|grafo. **BUILD SUCCEEDED**, reinstalado.
- [x] **F4** Dedup "um editor por bloco": `FileOpenCoordinator` ganhou `blockWindows[blockId]` + `registerBlockWindow`/`unregisterBlockWindow`/`focusBlockWindow`; `BlockEditorWindowWrapper` registra/desregistra a janela; `.openExisting` e `NodesPane.openBlock` **focam a janela existente** em vez de abrir aba. Fim do gap `.geo-conflict`. **BUILD SUCCEEDED**.
- [x] **F5** `DocTabsTests` (8: open/close/LRU/active-never-evicted/resync/dedup) + suíte completa **TEST SUCCEEDED**. #9 (busca) já satisfeito (sidebar reusa o search FTS do `BlocksPane`); #8 parcial (seed/wasSettled preservados + colapso do grafo via `leftHidden`); pause-ao-digitar fica como nice-to-have.

## ✅ Plano B completo (F1–F5) — BUILD + TEST SUCCEEDED, instalado (Release ad-hoc)
Falta só o **smoke visual** do NodesPane (sessão interativa). Workflow multi-agente nunca rodou (limite semanal de subagentes, reseta 19h Bahia) — implementado direto no loop principal.

## Como rodar o smoke (sessão interativa)
Vault de demo já em `~/Geo/Brains/evergreen` (5 notas linkadas). Para ver:
```bash
osascript -e 'quit app "Geo"'; sleep 1
export DEVELOPER_DIR="$HOME/Applications/Xcode-beta.app/Contents/Developer"
SRC=$(xcodebuild -scheme Geo -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3; exit}')
ditto "$SRC/Geo.app" /Applications/Geo.app && open /Applications/Geo.app
```
Depois: aba **Brains** → vault "Evergreen" → clicar numa nota abre como aba editável; digitar persiste no `.md`; grafo à direita = nota + vizinhos.

## Decisões
- Editor inline completo no centro (não só leitura) — reusa `ExternalFileEditorModel`+`BlockListView`, NÃO o wrapper `ExternalFileEditorView` (evita registro de janela no FileOpenCoordinator).
- Grafo direito = local (nota ativa + vizinhos de 1 salto).
- `BrainRegistry`/`Brains.swift` não é tocado.
- Arquivos novos adicionados ao `Geo.xcodeproj` via gem `xcodeproj` (objectVersion 55, sem grupos sincronizados).

## Polish UI — espaço vazio no topo (2026-06-26)
Diagnóstico **medido** nos screenshots (não chutado): a tab bar do editor e o grafo só começavam em ~pt72 do topo porque o `NodesPane` era `VStack { BlocksControlBar (largura cheia) ; splitContent }` — a toolbar virava uma faixa morta acima do editor+grafo (controles só sobre a sidebar).
- [x] **Fix**: toolbar movida pro header da **coluna da sidebar** (`sidebarColumn`); editor e grafo sobem pro topo do pane (estilo Obsidian). `leftHidden` ganhou toggle flutuante (`showSidebarButton`) já que o toggle vivia na toolbar. **BUILD + TEST SUCCEEDED** (DocTabs 8 + Brains 10), instalado em `/Applications/Geo.app`.
- [x] Branco acima do editor/grafo **confirmado sumido** pelo Gabriel.
- **Divisórias não arrastavam (nenhuma)** — o `PaneDivider` era um irmão fino espremido no HStack entre colunas; como o editor é NSView (`BlockListView`), um irmão lado-a-lado no mesmo nível-z perde o mouse. Correção do grafo é SwiftUI `Canvas` (não NSView), mas o `MouseEventMonitor` só captura dentro dos bounds do grafo.
  - ❌ Tentativa 1: `DividerInteraction` (NSViewRepresentable com tracking `.cursorUpdate` + toggle de hover) → **causou flicker** (loop hover/cursor). REVERTIDO.
  - ❌ Tentativa 2: `DividerHandle` SwiftUI puro como overlay → **arrastava a janela inteira** + chacoalhava. ROOT CAUSE achado: `GeoWindowChrome.swift:28` `window.isMovableByWindowBackground = true` ⇒ qualquer região não-opaca (`Color.clear`) tem `mouseDownCanMoveWindow == true` e o mouse-down MOVE A JANELA. Overlay SwiftUI puro não resolve.
  - [x] Tentativa 3 (best-of-N via g-swarm, 2 agentes worktree convergiram): `DividerHandle` agora é **NSView** (`DividerNSView`) que (1) `mouseDownCanMoveWindow=false` mata o window-drag; (2) `acceptsFirstMouse` + `hitTest` reivindica os bounds ⇒ ganha das colunas NSView por baixo; (3) trata `mouseDown/Dragged/Up` com delta em **window-space** (estável enquanto o handle se reposiciona); commit-on-end preservado; (4) cursor ↔ via push/pop guardado (sem `.cursorUpdate`); hover muda **só a cor desenhada** (sem relayout) ⇒ sem flicker. Continua overlay no topo do ZStack. Compartilhado → vale pro Brains. **BUILD SUCCEEDED** (Debug+Release), instalado **18:06**.
- ⏳ Falta o Gabriel confirmar: (a) as 2 divisórias arrastam e redimensionam (cursor ↔ no hover); (b) não move mais a janela / não chacoalha; (c) enquadramento do grafo (`initialFitScale 0.42`).

## Round 4 — bug sidebar-fechada + 2 customs (2026-06-26, build 18:54)
- [x] **BUG**: com a lista fechada (editor|grafo) a divisória não arrastava — o ramo `leftHidden` usava HStack com linha estática de 1px. **Fix**: novo `TwoColumnSplit` (reusa o `DividerHandle` NSView) no lugar.
- [x] **custom 1** (scrollbar fina+branca, app inteiro): swizzle de `NSScroller.drawKnob` (capsule branca de 5pt) + `knobStyle` getter→`.light` (cobre overlay), instalado em `AppDelegate`. Extensão em `GeoWindowChrome.swift`. ⚠️ cor/espessura tunáveis — não consigo verificar visual; overlay pode ignorar o drawKnob (por isso o `.light` junto).
- [x] **custom 2** (botões do editor destacado na UI acoplada → **barra inferior**): `DocTabsView` ganhou `statusAccessory` (mantém DocTabs genérico); `NodesPane` injeta `NodesDocControls` = chips Menu **Type · Layer · Status** ligados ao `blocksViewModel`, na status bar do editor embutido. Deferidos: Tag, Outline (precisa do document), Full-width (precisa de plumbing de largura), Lock (window-only, não se aplica embutido).
- **BUILD+TEST SUCCEEDED**, instalado e relançado 18:54.
- [x] **custom 2 completo** (build 19:00): Tag, Outline e Full-width acoplados. **Tag** + **Full-width** = chips no `NodesDocControls` (ligados a `setTag`/`setFullWidth`; Full-width reativo via `contentMaxWidth: ((OpenDocRef)->CGFloat)` threadado `DocTabsView→DocEditorPane→BlockListView`, `.infinity` vs 720). **Outline** = botão genérico no `DocEditorPane` (popover `OutlinePopover` sobre `OutlineExtractor.headings(model.document.blocks)`, foca via `document.focusRequest`) — vale pro Brains também. Status bar embutida agora: pop-out · outline · type · layer · status · tag · full-width · backlinks · words.

## REGRESSÃO editor travado → RESOLVIDA (build 19:11)
- Causa: o **swizzle global do `NSScroller`** (`method_exchangeImplementations` em drawKnob/knobStyle) congelava o text system app-wide. **REVERTIDO** → edição voltou (confirmado pelo Gabriel).
- **custom 1 reimplementado seguro (build 19:21)**: `SlimWhiteScroller` (NSViewRepresentable 0-size no LazyVStack do `BlockListView`) configura a **instância** do `enclosingScrollView` — `scrollerStyle = .overlay` + `verticalScroller.knobStyle = .light`. Config de aparência por-instância, NUNCA swizzle global → não toca no text system. Lição: nunca swizzlar métodos de classe AppKit globalmente (NSScroller) num app com NSTextView.

## Round 5 — bug "não digita" + reordenar abas (2026-06-27)
- [x] **BUG digitação morta (busca + editor)** — no NodesPane os dois surfaces de texto não aceitavam tecla. Causa: `MouseNSView` do grafo (`GraphSimulation.swift`) com `acceptsFirstResponder = true`. No layout antigo era inofensivo; no NodesPane (grafo + editor + busca na MESMA janela) clicar no grafo faz a janela promover a view a first responder e **rouba o teclado** do editor/busca. O grafo não trata tecla nenhuma. **Fix**: `acceptsFirstResponder = false` (mouse continua via hit-test; pan/zoom/drag/tap intactos). Co-suspeitos descartados: `SlimWhiteScroller` é per-instance e não toca eventos; monitores `keyDown` (wikilink/block-selection) passam o evento adiante quando inativos.
- [x] **Reordenar abas por drag** — `DocTabsModel.move(from:to:)`; `PaneTabBar` ganhou `onReorder` + `.onDrag/.onDrop` (`TabReorderDropDelegate`, reorder live ao passar sobre vizinhos, tab arrastada esmaecida). Genérico no `DocTabsView` → vale Nodes **e** Brains. Ordem sobrevive `resync` (model é dono do array).
- **BUILD SUCCEEDED** (Debug+Release ad-hoc), instalado em `/Applications` e relançado.
- ⏳ Falta o Gabriel confirmar (sem window server no job): (a) digita no editor; (b) digita na busca ⌘F; (c) arrasta aba pra reordenar.

## Round 6 — CAUSA RAIZ real do "não digita" (ultracode swarm, 2026-06-27)
- O fix do Round 5 (`acceptsFirstResponder=false` no grafo) **não era a causa** — digitação continuou morta. Swarm adversarial (5 lentes → verify → fix, 16 agentes) achou e **git-history confirmou** a real:
- [x] **Latch de key-window do NotchPanel.** Commit `fbc75f3` trocou `NotchPanel.canBecomeKey` de `false` hardcoded → `canBecomeKeyEnabled` (true enquanto o notch está expandido). O notch tem o **próprio** campo de busca SwiftUI (`DockTopBar`); focar nele faz o NotchPanel virar a **key window** do macOS. Ao dispensar (`searchActive→false`), o código só fazia `panel.resignKey()` — que **larga** o key do panel mas **nunca promove** a janela principal de volta. App fica **sem key window** → macOS só entrega `keyDown` à key window → **todo `TextField` SwiftUI da janela principal morre junto** (⌘F overlay + busca da sidebar). Explica os 3 discriminadores: nível-janela (não editor), "do nada" (um toque na busca do notch vira o latch), e por que `acceptsFirstResponder` não ajudou (first-responder intra-janela é irrelevante sem key window).
- **Fix** (`NotchWindowController.swift`): helper `restoreMainWindowKey()` (`NSApp.windows.first{ visível && !NSPanel }.makeKeyAndOrderFront`, espelha `GlobalHotkeyManager`) chamado nos 2 pontos em que o panel larga o key — `state==.hidden` e `searchActive→false`. Não mexe em `canBecomeKeyEnabled` (a busca do notch precisa do panel key enquanto focada). `makeKeyAndOrderFront` não chama `NSApp.activate` → não rouba foco de outro app; notch fica visível (`level=.statusBar`).
- `acceptsFirstResponder=false` (Round 5) **mantido** — é higiene correta, só não era a causa.
- **BUILD SUCCEEDED** (Release ad-hoc), instalado e relançado.
- ⏳ Confirmar (Gabriel): repro = focar busca do notch → dispensar → no main window ⌘F e busca da sidebar voltam a digitar; e ciclar isso várias vezes.

## Round 7 — STOP de chutar: reverter falsos consertos + instrumentar (2026-06-27)
- Gabriel (com razão) chamou de "cascata de falsos consertos". Furo lógico decisivo: **o bug existe desde a 1ª mensagem dele, antes de FIX A e FIX B existirem** → nenhum dos dois pode ser a causa original. g-swarm+g-triad (mapa da máquina de estados de key-window/foco/eventos) confirmou: FIX B (`restoreMainWindowKey`) é **nocivo** (`NSApp.windows.first{visível && !NSPanel}` pega janela de editor destacada → rouba key da principal), e CGEventTap está **inocente** (só consome ⌘⇧V/⌘⇧A; tecla normal sempre passa).
- [x] **Revertido FIX A** (`acceptsFirstResponder` volta a `true`, GraphSimulation) e **FIX B** (removido `restoreMainWindowKey` + as 2 chamadas, NotchWindowController) → **baseline limpo = estado da mensagem 1**.
- [x] **Instrumentação agnóstica** (`KeyWindowDebugLogger` em GeoApp.swift, ligada no `applicationDidFinishLaunching`): loga toda mudança de `NSApp.keyWindow` / `firstResponder` / `isActive` (por evento becomeKey/resignKey/active + poll de 1s on-change) pra **arquivo** `~/geo-keywindow-debug.log` (unified log `os_log` é ilegível do background job). `start()` trunca o arquivo a cada sessão.
- **BUILD SUCCEEDED**, instalado e rodando. Próximo: Gabriel reproduz o estado morto na instância atual (sem relançar) → ler o log → consertar **com evidência**.
- ⚠️ Código de debug temporário (`KeyWindowDebugLogger` + log file) — remover depois do diagnóstico.

## Round 8 — digitação RESOLVIDA + consolidação da busca (2026-06-28)
- ✅ **Bug "não digita" CONFIRMADO resolvido pelo Gabriel** após reverter FIX B (o nocivo) → baseline limpo. Causa raiz era o próprio FIX B (meu) roubando key pra janela errada. Instrumentação (`~/geo-keywindow-debug.log`) provou: janela principal sempre key quando ativa, zero transição ruim.
- [x] **Limpeza**: removido o `KeyWindowDebugLogger` temporário + arquivo de log (loop g-loop encerrado, DONE).
- [x] **Busca unificada no ⌘F** (3 itens do Gabriel):
  - **Item 1** — removido o input de busca da sidebar (`BlocksControlBar`: tirado `searchControl`/`searchField`/`expandSearch`/`collapseSearch` + param `searchShortcutEnabled` + `navigationStore`). A lista já filtra por `searchTexts[.nodes]` (BlocksPane:144), então o ⌘F agora filtra **lista E grafo** juntos. `BlocksControlBar` só é usado no NodesPane → seguro.
  - **Item 3 (bug)** — clicar num nó pesquisado "voltava ao estado inicial": o overlay do ⌘F tinha um `Color.black.opacity(0.001).ignoresSafeArea().onTapGesture{closeGraphSearch()}` cobrindo o pane e **engolindo o clique no nó**. Removido o backdrop; a search box agora se posiciona via `.frame(maxWidth/Height:.infinity, alignment:.top)` (área vazia não captura toque → clique chega no grafo). Dismiss via Esc + botão limpar.
  - **Item 2 (amadurecer)** — `Enter` na busca abre o melhor match (exato → prefixo → primeiro contains) via `openFirstMatch()`; grafo continua clicável durante a busca (grátis da remoção do backdrop).
- **BUILD SUCCEEDED** (Release), instalado e relançado.
- ⏳ Confirmar (Gabriel): (a) sidebar sem o input de busca; (b) ⌘F filtra lista+grafo; (c) clicar no nó pesquisado ABRE (não reseta); (d) Enter abre o melhor match.

## Notas
- Build Release p/ rodar: `DEVELOPER_DIR=Xcode-beta`, `ditto` p/ `/Applications` (Debug crasha por @rpath).

## Fase B — Reminders mirror (PASSO 3/4: inbound reconcile) (2026-06-29)
- Espelho Apple Reminders bidirecional. Outbound (criar/editar/concluir/apagar EKReminder) já existia em `RemindersAdapter.mirror` chamado nos seams do `TasksStore` (create/update/replace/delete/import). Verdade canônica = JSON; Reminders = projeção pro iPhone. Eventos continuam no Calendar (não viram reminder).
- [x] **Echo-suppression por reminder-id** (`RemindersAdapter`): `recentWrites[id]` carimbado em todo write (create/update/delete), `wasRecentlyWritten(id)` com grace de 2.0s — espelha o padrão `recentWriteTimestamps` da camada de arquivo.
- [x] **Inbound reconcile** (`RemindersSyncCoordinator`, novo): observa `.EKEventStoreChanged` no store COMPARTILHADO (`EventKitAdapter.shared.store`), faz fetch via `predicateForReminders`, diffa contra `externalEKReminderID` conhecidos e reflete de volta: `isCompleted` → status (.completed/.pending), título/data editados → atualiza task, reminder apagado no iPhone → `clearReminderMirror` (limpa sombra; JSON vence). Habit completion roteia pra `completeHabitOccurrence` (occurrence-based, não .completed permanente). Echo ignorado via `wasRecentlyWritten`.
- [x] **TasksStore** ganhou `applyInboundReminderEdit` + `clearReminderMirror` (mutam JSON via persist SEM re-mirror → evita bounce outbound).
- [x] Wiring no `GeoApp`/`AppContainer`: `remindersSyncCoordinator.start()` no didFinishLaunching, `.stop()` no willTerminate. Arquivo novo registrado no `project.pbxproj` (target Geo).
- **BUILD Debug SUCCEEDED** (`xcodebuild ... -configuration Debug build CODE_SIGNING_ALLOWED=NO`).

## Hermes base update v0.17.0 → v0.18.0 (2026-07-01)
- [x] `biel-code` reset pro **HEAD da main upstream `76a468e5`** (= tag `v2026.7.1` + commit curated-models fable-5/sonnet-5), P2 reaplicado limpo (carried `65a610b0`), tag `prd` movida (anterior v0.17.0: `5dd495c6`). `git rev-list HEAD..origin/main` = 0 behind; o "1 commit behind" do `--version` é cache do checker.
- [x] venv sincronizado via `uv pip install -e '.[messaging,mcp]'` (aiohttp 3.13.4→3.14.1, qrcode novo).
- [x] Gateway reiniciado via launchd — boot verde: hook geo-context carregado, Telegram conectado, plugins geo-tools/geo-search-tool enabled.
- **install.sh PULADO de propósito**: `~/.hermes/config.yaml` vivo divergiu do template do repo (hermes rematerializou o arquivo — carrega `plugins.enabled`, toolset spotify, `api.enabled: false`); `template_config` sobrescreveria e desligaria os plugins Geo. Backportar os deltas pro template antes do próximo install.sh.
- ⏳ Smoke P2 (Gabriel): mandar 1 msg no Telegram e conferir que o turno vê contexto Geo fresco.

## GeoMobile iOS — integração pós-features (2026-07-01)
- [x] Features/{Tasks,Today,Chat,Agents} + EventKitService integrados sobre o skeleton; **BUILD SUCCEEDED** de primeira (`ruby gen_project.rb` + `xcodebuild -scheme GeoMobile -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`, Xcode-beta iOS 18 SDK).
- [x] Warnings novos zerados: `TodayViewModel.init` default arg `.shared` main-actor (vira erro em Swift 6) → param opcional `?? .shared`; `ChatView` weak captures aninhados → capture list `[weak viewModel, weak speech]` no `.task`.
- Zero warnings de código no build final; GeoCore/ e Geo/ intocados.

## GeoMobile v1 — GeoBridge operacional (2026-07-01)
- [x] **GeoBridge instalado e vivo**: LaunchAgent `ai.geo.bridge` (KeepAlive), bind `100.123.44.9:8643` (só tailnet, nunca 0.0.0.0), token bearer em `~/.hermes/geobridge.token` (600). Código+contrato em `GeoBridge/` (python3 stdlib, arquivo único).
- [x] **hermes api_server LIGADO** (`127.0.0.1:8642`, loopback — o bridge é a única face na tailnet): `platforms.api_server.enabled: true` + key em `platforms.api_server.extra.key` (== `~/.hermes/api_server.key`). Backup do config em `config.yaml.bak-geobridge`. ⚠️ é MAIS um delta vivo vs template — o próximo `install.sh` do hermes desligaria o api_server (ver nota do update v0.18.0 acima).
- [x] **Smoke fim-a-fim verde** (via IP da tailnet): /health 200 sem auth; /tasks 401 sem token e 106 tasks com token (bytes verbatim); /dispatches lista 3; /chat/stream POST → hermes respondeu streaming (run.started→assistant.delta→done, sessão auto-criada).
- Review multi-agente: 18 achados → 12 confirmados → todos corrigidos + gates re-verificados (smoke 8/8, build iOS verde).
- Gotcha ops: `pkill -f "python3 .*geobridge"` NÃO casa (macOS resolve argv0 pra Python.app) — gerenciar via `launchctl kickstart/bootout gui/501/ai.geo.bridge`.
- ⏳ Deploy no iPhone físico: precisa Apple ID logado no Xcode (0 identidades de codesigning na máquina — free personal team) + Tailscale app no iPhone + token/URL na tela Settings do app. Loop de deploy desenhado (g-loop).

---

# STATUS — GeoMobile v2 · workflow 1 (Tasks) — 2026-07-01

Plano: `docs/reviews/geomobile-v2-plan-2026-07-01.md` (PLANO 1, ordem A→C→B). Implementação completa; **gate final verde em 2026-07-02** (build device + smoke bridge + deploy vivo + install iPhone).

- [x] **A. Agrupamento Overdue/Today/Upcoming** — `TasksViewModel` publica `overdue`/`today`/`upcoming` (pending & `isOverdue` kind-aware / `isDateInToday(anchorDate)` / resto; sort anchorDate→priority por bucket); `TasksView` com 3 Sections (Overdue em vermelho), vazias ocultas; swipe-complete e disclosure de concluídas mantidos.
- [x] **C. Reopen por swipe** — `reopen(_:)` no VM espelhando `complete()` (otimista+rollback, re-bucket via `applyPending`); swipe leading "Reopen" (arrow.uturn.backward) nas linhas de Completed Today.
- [x] **B. Criar task do celular** — bridge `POST /tasks` (`_create_task`: valida id/title/body.kind/createdAt → 400; `O_CREAT|O_EXCL` → 409 `task_exists`; tempfile+fsync+os.replace; 201 com bytes); CONTRACT.md v1→**2** (princípio 4 revisado + seção POST /tasks: datas ISO-8601 com Z SEM fração, iOS nunca envia `externalEKEventID`); `BridgeClient.iso8601Encoder`; `BridgeTasksRepository.create` (TaskItem de TaskDraft, id UUID maiúsculo, `postData("/tasks")`); botão "+" → `NewTaskSheet` (título+DatePicker due+Picker priority; kind fixo task, reminders `[.atTime()]`); insert otimista com rollback no VM.
- ✅ `python3 -m py_compile geobridge.py` + smoke in-process do handler (fake IO, tasks dir temp): 201/409/400×4/401 verbatim, bytes no disco == resposta, `/tasks/{id}/complete` intacto. Sem arquivos Swift novos → `gen_project.rb` não precisa de regen.
- [x] **Gate final (2026-07-02)**: `ruby gen_project.rb` + **BUILD SUCCEEDED** no device físico (`-destination 'platform=iOS,id=2C85…'`, team 6RRNRWCXSD, profile provisionado ok). Smoke isolado do bridge (temp dir + token temp, `127.0.0.1:8999`): health 200 · POST /tasks 201 com arquivo byte-fiel à resposta · 401 sem auth · 400 body inválido · 409 id duplicado · GET /tasks lista · complete 200→completed · reopen 200→pending. Bridge vivo redeployado (`launchctl kickstart -k gui/501/ai.geo.bridge`) → `http://100.123.44.9:8643/health` 200. App **instalado no iPhone** via devicectl (bundle `com.gabrielmendonca.geomobile`); `process launch` falhou só por device bloqueado (FBSOpenApplicationErrorDomain 7 — abrir na mão).
- ⏳ Verificação manual (Gabriel): task criada no celular → Geo.app ~1s → Apple Calendar; refresh traz `externalEKEventID`; completar 2× idempotente; off-tailnet = erro claro sem crash.

# STATUS — GeoMobile v2 · workflow 2 (Chat voice-first) — 2026-07-02

Plano: `docs/reviews/geomobile-v2-plan-2026-07-01.md` (PLANO 2). Implementação completa; **gate final verde em 2026-07-02** (build device + install iPhone). Escopo EXCLUIU os opcionais background/tela-bloqueada (UIBackgroundModes) e o campo `voice` no contrato — não implementados por decisão.

- [x] **Modo Conversa hands-free** — `VoiceSessionController` (máquina de estados `idle/listening/thinking/speaking`, absorve o antigo SpeechController) dirige o ciclo ouvindo→VAD por silêncio auto-envia→pensando→falando→ouvindo; hold-to-talk vira fallback.
- [x] **STT on-device** — `SpeechRecognitionService` com `SFSpeechRecognizer` pt-BR, `requiresOnDeviceRecognition=true` (checa `supportsOnDeviceRecognition`, degrada pra rede com aviso), recognizer reciclado por turno.
- [x] **TTS streaming por sentença** — `SpeechSynthesisService` bufferiza deltas → corte em `.!?\n`/~160 chars → fila do AVSpeechSynthesizer; `ChatViewModel` expõe deltas e consome `run.started`/`message.started`/`tool.progress` pro estado "pensando".
- [x] **IA decide voz vs texto (camada 1)** — `ResponseModality` classifica cliente (code fence/tabela/lista/links/comprimento → texto; curto conversacional → voz+texto). Sem toque no bridge (marcador `⟦voice⟧`/campo `voice` = fase 2, fora deste escopo).
- [x] **Barge-in full-duplex com AEC** — `AudioSessionManager` `.playAndRecord`+`.voiceChat` (`.duckOthers/.allowBluetooth/.allowBluetoothA2DP`, trata interruption+routeChange); fala sustentada → `stopSpeaking(.immediate)` + limpa fila + cancela SSE (`BridgeClient` cancel existente) + novo turno.
- [x] **UI orbe** — `ConversationOrbView` animado por estado; `ChatView` refatorada voice-first (SpeechController removido).
- [x] **Gate final (2026-07-02)**: `ruby gen_project.rb` + **BUILD SUCCEEDED** no device físico (`-destination 'platform=iOS,id=2C85…'`, team 6RRNRWCXSD, `-allowProvisioningUpdates`, profile provisionado ok). App **instalado no iPhone** via devicectl (bundle `com.gabrielmendonca.geomobile`, install ok após retry de túnel transitório kAMDRemoteConnectError); `process launch` falhou só por device bloqueado (FBSOpenApplicationErrorDomain 7 — abrir na mão). Bridge: NENHUMA mudança (conforme plano).
- ⏳ Checklist manual no aparelho (Gabriel) — só validável lá: (1) TTS falando alto NÃO se auto-dispara (AEC segura o próprio áudio); (2) barge-in para o TTS e captura só a fala do usuário; (3) modo avião prova STT on-device; (4) time-to-first-audio na 1ª sentença (streaming por sentença); (5) marcador nunca aparece na tela; (6) AirPods conectar/desconectar no meio do turno (routeChange).

# GeoMobile v2 · workflow 3 (Agents = terminal real) — 2026-07-02
- [x] **Bridge /term/*** — `geobridge.py`: `GET /term/stream` (pty.fork + `tmux new-session -A -s mobile`, loop select, chunks base64 em SSE, keepalive 15s, EIO/idle/takeover→`event: done`), `POST /term/input` (base64→os.write no master_fd), `POST /term/resize` (ioctl TIOCSWINSZ). Registry global com lock, `TermSession`, idle-detach 600s por input, last-writer-wins.
- [x] **Segundo token** — `~/.hermes/geobridge.term.token` (install.sh gera); `/term/*` valida só esse token; feature gate `GEO_TERM_ENABLED` (404 se off ou token vazio); token principal NÃO abre `/term/*`; input nunca logado.
- [x] **CONTRACT.md v2→3** — seção Terminal, framing base64, tmux persistência, last-writer-wins, carve-out do princípio 4 com aviso de blast radius (shell arbitrário como biel).
- [x] **Plist** — `ai.geo.bridge.plist` (repo + vivo) com env novos, `GEO_TERM_ENABLED=1`.
- [x] **iOS** — SwiftTerm via SPM em `gen_project.rb` (XCRemoteSwiftPackageReference); `Features/Terminal/TerminalViewModel` (SSE base64 + input/resize com term token) + `TerminalHostView` (UIViewRepresentable sobre SwiftTerm.TerminalView, accessory bar nativa: Esc/Tab/Ctrl sticky/setas/`|~-`); `BridgeClient` ganha param `token`; `BridgeConfig.termToken` (2ª conta Keychain); `SettingsView` SecureField "Terminal token"; botão Terminal na toolbar de `AgentsView`.
- Review 3 lentes → 3 achados confirmados corrigidos (vazamento fd/zumbi no `_term_stream`, idle-detach derrubando attach ativo, race no `reconnect()`).
- **Gate**: BUILD device 🟢 SUCCEEDED (SwiftTerm resolvido); smoke bridge 🟢 6/6 (auth 401, echo, resize 120x49, 404 com flag off, reconexão+persistência tmux, log sem teclas); bridge vivo recarregado (bootout+bootstrap por env novos) 🟢 /health 200 + /term/stream responde SSE com term token; INSTALL no iPhone 🟢.
- **Manual pendente**: colar o term token nas Settings do app (`cat ~/.hermes/geobridge.term.token` no Mac); no aparelho — vim/htop renderizam, ctrl-c interrompe, loop `while true` sobrevive a lock/troca-de-tab/kill do app, log sem teclas.

# GeoMobile · reskin visual "Air" — 2026-07-02
- Design system novo `GeoMobile/Shared/AirTheme.swift`: tokens (skyCanvas #426188, actionBlue #2b7fff, cloudWhite, charcoalText, hazeGrey), raios (card 14/botão 8/input 4), `SkyBackground` (gradiente), `.airCard()` frosted, `AirOutlineButtonStyle` (outline pill), `AirAppearance.apply()` (nav/tab bar).
- Aplicado: RootView (tint actionBlue, `.preferredColorScheme(.light)`, engrenagem circular frosted), Today/Tasks/Agents (listas insetGrouped sobre SkyBackground, linhas cloudWhite, estados vazio/erro no sky com botão outline branco), Chat (fundo sky, balão user azul / assistant vidro fosco, input hazeGrey), Settings (Form no sky, seções brancas, Test Connection azul).
- Fontes custom do Air (Inter/Oswald/Dancing Script) NÃO empacotadas — usa SF Pro; follow-up se quiser o toque tipográfico (exige .ttf + gen_project.rb).
- Gate: BUILD device 🟢 SUCCEEDED, INSTALL 🟢 (launch bloqueado por device locked — abrir na mão).

# GeoMobile · fix ATS (root cause "nada aparece") — 2026-07-02
- CAUSA RAIZ: iOS 27 aplica App Transport Security mesmo pra IP literal → "Bridge unreachable: ... requires the use of a secure connection". Toda request HTTP do app era bloqueada ANTES de sair → 4 telas vazias + terminal preto. Suposição anterior de isenção IP-literal estava ERRADA.
- FIX: `GeoMobile/Info.plist` (já referenciado por INFOPLIST_FILE no gen_project.rb) ganhou NSAppTransportSecurity → NSAllowsArbitraryLoads=true + NSAllowsLocalNetworking=true. Aceitável: app pessoal, tailnet privada (WireGuard já cifra ponta-a-ponta).
- Acabamento junto: títulos de nav em Cloud White sobre o sky (guia Air); empty/error states viraram AirStateCard (cartão frosted centralizado: ícone + título + mensagem + ação outline) em vez de texto solto.
- Gate: BUILD device SUCCEEDED, INSTALL ok (launch bloqueado por device locked).
- PENDENTE no aparelho: abrir app → Settings → URL http://100.123.44.9:8643 + token principal (~/.hermes/geobridge.token) + Terminal token (~/.hermes/geobridge.term.token) → agora Test Connection deve passar e as telas populam.

# GeoMobile · conexão RESOLVIDA via HTTPS (tailscale serve) — 2026-07-02
- CAUSA REAL: iOS 27 beta NÃO honra NSAllowsArbitraryLoads (ATS bloqueava todo HTTP mesmo com a exceção no Info.plist verificada no binário). Safari conectava (não aplica ATS de app), o app não.
- FIX DEFINITIVO: HTTPS real. `tailscale serve --bg --https=443 http://127.0.0.1:8643` expõe https://biel-macbook-pro.tail091418.ts.net (cert Let's Encrypt, tailnet-only) → proxia pro bridge. iOS aceita sem exceção nenhuma.
- Bridge rebindou de 100.123.44.9 → **127.0.0.1** (GEO_BRIDGE_BIND no plist vivo + repo); serve é o único front na tailnet. Arquitetura mais segura: bridge não fica mais exposto direto na tailnet. serve não consegue proxiar pro IP da própria tailnet (502/loop) — por isso loopback.
- App: URL de fábrica agora https://biel-macbook-pro.tail091418.ts.net (BridgeSecrets.baseURL). Tokens embutidos (Secrets.swift, git-ignored) → install limpo conecta sozinho, zero digitação.
- VERIFICADO no aparelho: /health 200, /tasks 200 (token de fábrica), /dispatches 200, **terminal vivo** (/term/stream 200 + POST /term/input/resize 200 em rajada = digitando de verdade). Source no log = 127.0.0.1 (proxied via serve).
- Nota: tráfego do iPhone aparece como 127.0.0.1 no geobridge.log (serve proxia do loopback) — não dá mais pra distinguir por IP; distinguir por /tasks 200 autenticado.
- Pendência de higiene: CONTRACT.md ainda diz "bind tailnet"; atualizar pra "bind loopback + tailscale serve" quando for commitar.

# GeoMobile · terminal usável p/ Claude Code + fix engrenagem — 2026-07-02
- Pedido: terminal PRETO PURO (sem moldura/sky), foco em USABILIDADE rodando Claude Code (ilegível a 13pt — TUI de 80 col espremida no portrait).
- TerminalHostView: fonte default 13→**10pt**, **pinch-to-zoom** (UIPinchGestureRecognizer, base no .began × scale, 7–24pt, persistido em @AppStorage terminal.fontSize) + botões A-/A+ no header. Preto puro mantido.
- **Landscape liberado** (gen_project.rb INFOPLIST_KEY_UISupportedInterfaceOrientations += LandscapeLeft/Right) — dobra colunas, Claude Code renderiza de verdade. App inteiro rota agora.
- Header do terminal: status dot (verde/laranja) + "mobile" + A-/A+ + reconnect; tab bar escondida (.toolbar(.hidden, for: .tabBar)) = +altura.
- FIX engrenagem: overlay global do RootView SOBREPUNHA o topo do terminal (círculo claro). Removido; virou `.settingsToolbar()` (modifier em AirTheme) dentro do nav de cada aba (Today/Tasks/Chat/Agents). Some do terminal, não colide mais.
- Gate: BUILD device SUCCEEDED, install+launch OK, terminal reconecta (/term/resize + /term/input 200 no log). Fluxo Claude Code: abrir terminal → girar landscape → pinçar fonte.

# GeoMobile · terminal scroll + fit-to-width — 2026-07-02
- SCROLL (pedido principal): raiz = Claude Code roda em tmux/alt-screen, histórico no tmux não no buffer local → arrastar não fazia nada. Fix no geobridge.py `_term_spawn`: chained `; set -g mouse on ; set -g history-limit 100000 ; bind -n PageUp copy-mode -u`. Verificado no tmux vivo: mouse on, WheelUpPane→copy-mode-e (gesto), PPage→copy-mode-u (tecla pgup da barra), MouseDrag→copy-mode. Sair do copy-mode = q.
- iOS: `term.allowMouseReporting = true` (SwiftTerm forwarda touch→wheel qdo app pede mouse tracking).
- FIT-TO-WIDTH: botão ⟷ (arrow.left.and.right.square) calcula fonte p/ 80 colunas = fontSize * cols/80 (viewModel.cols agora @Published). Landscape + fit = Claude Code legível a ~80 col.
- Reload: kickstart bridge + `tmux kill-session -t mobile` (recria com mouse on no próximo attach). bridge loopback → http direto dá 000, usar https serve.
- Gate: BUILD SUCCEEDED, install+launch OK, tmux mobile attached com mouse/history/PPage confirmados.
- Uso Claude Code: abrir terminal → landscape → ⟷ (fit 80) → scroll por arrasto ou pgup (q p/ sair do copy-mode).

# GeoMobile · terminal scroll 2-dedos + cor travada — 2026-07-02
- Pesquisei o fonte do SwiftTerm: TerminalView É UMA UIScrollView; no iOS, pan de 1 dedo com allowMouseReporting=true vira SELEÇÃO do tmux (não wheel), e alt-screen não tem scrollback local → por isso arrasto não rolava.
- FIX scroll: UIPanGestureRecognizer de 2 DEDOS no Coordinator emite sequências SGR de wheel (ESC[<64;1;1M up / ESC[<65;1;1M down) via viewModel.send→/term/input; tmux (mouse on) lê e rola copy-mode. Batch por evento (min(count,8)), step 14pt, drag-down=wheel-up (natural). pgup (PPage→copy-mode-u) segue como fallback.
- COR: nativeForegroundColor=white, nativeBackgroundColor=black, caretColor=white, overrideUserInterfaceStyle=.dark → idêntico em light/dark mode.
- Gate: BUILD SUCCEEDED, install OK (launch bloqueado por device locked — abrir na mão).
- A verificar (tátil): scroll 2-dedos rola o Claude Code; se falhar, testar injeção direta da seq SGR no PTY.

# GeoMobile · terminal multi-tab + header slim + fix pinch/scroll — 2026-07-02
- PINCH×SCROLL (bug): ambos 2-dedos, disparavam juntos. Fix = mode-lock no Coordinator (GestureMode idle/scroll/zoom): trava no 1º movimento significativo (translation.y>6pt=scroll, |scale-1|>0.06=zoom), o outro retorna. Simultaneous recognition true mas só um AGE.
- HEADER SLIM: removido nav bar do sistema (navigationBarHidden), barra própria ~34pt: back chevron + ScrollView horizontal de chips de sessão + "+" + Menu (•••: fit/A+/A-/reconnect) + status dot. preferredColorScheme(.dark) p/ status bar clara.
- MULTI-TAB: bridge ganhou `?session=` em stream/input/resize (TERM_SESSION_RE `^[A-Za-z0-9_-]{1,32}$`, fallback mobile), registry keyed por sessão, TermSession.session; + `/term/list` (GET, subprocess tmux list-sessions) e `/term/kill` (POST). App: TerminalViewModel(session:) + switchTo/onReset (feed ESC[3J[2J[H ao trocar); @AppStorage terminal.sessions (csv); chip tap=switch, +=nova (mobile/mobile2…), x=fecha+kill. Sessões tmux persistem no servidor.
- Gate: BUILD SUCCEEDED, install+launch OK, /term/list testado (["mobile"]).

# GeoMobile · terminal scroll 1-dedo + pinch removido — 2026-07-02
- Pedido: scroll com UM dedo e remover o pinch-to-zoom (zoom fica só no menu ••• A+/A-/fit).
- Raiz do bloqueio de 1 dedo: SwiftTerm iOS liga `panMouseGesture` via `mouseModeChanged` quando o tmux pede mouse tracking → pan de 1 dedo virava mouse press/motion (seleção no tmux). O método é `open`.
- FIX: subclasse `GeoTerminalView: TerminalView` com `mouseModeChanged` vazio → o pan de mouse-report do SwiftTerm nunca é instalado; taps continuam reportando clique e long-press→Select (seleção local) segue vivo.
- Pan de scroll do Coordinator: min/max touches 2→1. Pinch removido inteiro (UIPinchGestureRecognizer, handlePinch, GestureMode/mode-lock, onFontSizeChange) — handleScrollPan virou acúmulo simples de translation.y (step 14pt) → SGR wheel via /term/input.
- Gate: BUILD SUCCEEDED, install OK (launch bloqueado por device locked — abrir na mão).
- A verificar (tátil): 1 dedo rola o Claude Code sem selecionar; conferir se o pan nativo da UIScrollView não briga (alt-screen contentSize==bounds, não deve).

# GeoMobile · reconnect rápido pós-lock + light/dark mode — 2026-07-02
- Workflow multi-agente (2 tracks Opus + review adversarial + build gate). Sintoma: bloquear/desbloquear o iPhone deixava o terminal morto até ~90s (stream TCP meio-aberto + connect() early-return em streamTask != nil, sem scenePhase, sem retry).
- RECONNECT: TerminalScreen observa scenePhase (.background → disconnect + wasBackgrounded; .active → reconnect com onReset = repaint limpo do tmux). TerminalViewModel ganhou runStreamLoop: retry automático com backoff 0.5s→1→2→cap 5s enquanto visível, flag @Published reconnecting ("reconnecting…" no header ao lado do dot), reconnect() agora faz onReset. Review Opus achou+corrigiu bug real: guard de generation dentro do loop de mensagens (buffer unbounded do AsyncThrowingStream vazava bytes de sessão antiga pro terminal recém-trocado).
- LIGHT/DARK: RootView perdeu o .preferredColorScheme(.light) forçado — app segue o sistema. AirTheme com tokens adaptativos via UIColor dynamic provider (light byte-idêntico; dark = night-sky #0B1220/#17233B, texto #ECEFF4, actionBlue +6% no dark). Novo token cardSurface (white→#1C2536) em todos listRowBackground (Today/Tasks/Agents/Settings); ChatView stroke .black→.primary; cloudWhite continua literal nos 2 usos on-blue. Terminal e DispatchDetailView (forced-dark) intocados — terminal segue preto puro nos 2 modos.
- Bridge NÃO tocado (fix 100% client-side). Gate: build gate do workflow SUCCEEDED, install + launch OK no aparelho.
- A verificar (tátil): bloquear/desbloquear → terminal volta ≤2s com "reconnecting…" visível durante a janela; alternar light/dark no sistema → app inteiro adapta, terminal permanece preto.

# GeoMobile · terminal segue o sistema (branco no light / preto no dark) — 2026-07-02
- Pedido (screenshot do terminal do Mac): terminal branco/texto preto no light mode, preto/texto branco no dark — substitui o "preto puro sempre".
- Gotcha SwiftTerm: setters de nativeForeground/BackgroundColor resolvem a UIColor na hora (getTerminalColor) — dynamic color NÃO adapta sozinha. Fix: applyColors(term:dark:) estático + re-aplicação em updateUIView quando context.environment.colorScheme muda (Coordinator.isDark evita colorsChanged redundante).
- TerminalScreen: removido .preferredColorScheme(.dark); fundo/header = Color(uiColor: .systemBackground); textos/chips brancos → .primary (+opacities iguais); overrideUserInterfaceStyle removido; term.backgroundColor = .systemBackground (UIView adapta nativo).
- Gate: BUILD SUCCEEDED, install OK (launch bloqueado por device locked).
- A verificar (tátil): alternar dark/light do sistema COM o terminal aberto → repaint imediato de fundo/texto/caret/header.

# GeoMobile · terminal touch-first + fim da briga de layout com o Mac — 2026-07-02
- Queixas: (1) usar o terminal no celular REDIMENSIONAVA o layout no Mac (mesma sessão tmux); (2) teclado sempre aberto; (3) view não-responsiva, resize buggy.
- RAIZ (1): attach do celular era client tmux normal → window-size latest segue o client mais recente; e `set -g mouse on` do bridge vazava GLOBAL pro server tmux do Mac. Validado empiricamente com clients PTY falsos: flag `ignore-size` (tmux 3.5a) chained no attach (`; refresh-client -f ignore-size`) mantém a janela intocada.
- BRIDGE: `_term_spawn(session, ignore_size)` — aplica ignore-size quando `_term_has_sizing_client` (list-clients sem ignore-size) detecta outro client (Mac); kill do client antigo movido pra ANTES do spawn (+150ms) pra não contar a si mesmo; `mouse on` agora session-scoped (global limpo com `set -gu mouse`, sessão mobile atual re-setada); novo GET `/term/winsize` → {cols,rows,shared}. Reload via kickstart, health 200, rota 401 sem token OK.
- APP: teclado sob demanda — removido becomeFirstResponder no makeUIView; botão ⌨ no header (viewModel.onToggleKeyboard) e tap no terminal ainda invoca (singleTap nativo do SwiftTerm); resize DEBOUNCED 200ms no TerminalViewModel (mata thrash de teclado/rotação); "mirror mode": ao conectar (delay 600ms) busca winsize e se shared ajusta fontSize por ratio min(cols,rows) pra mostrar a janela inteira do Mac; menu ganhou "Fit remote" (força o fit manual).
- Comportamento resultante: sessão compartilhada = Mac manda no tamanho, celular espelha com fonte auto-ajustada; sessão só-do-celular = celular manda (primeiro attach solo é sizing client); lock/unlock re-avalia o modo a cada reconnect.
- Gate: py_compile OK, bridge health 200, BUILD SUCCEEDED, App installed (launch remoto RequestDenied — tela bloqueada, abrir na mão).
- A verificar (tátil): digitar no celular NÃO mexe no layout do Mac; ⌨ mostra/esconde teclado; rotação/teclado sem glitch; fonte auto-ajusta ao abrir sessão compartilhada.

# GeoMobile · UX/UI calibration + fix tap-to-complete — 2026-07-05
- Sessão de calibração UX/UI (2 tracks disjuntos + spec g-triad + review adversarial + build/screenshot gate). Track A = `Features/Tasks/TasksView.swift`; Track B = `Shared/AirTheme.swift` + `RootView.swift` + `Features/{Today,Chat,Agents,Settings}/`.
- **FIX "não consigo marcar tarefas como feito" (CAUSA RAIZ)**: o círculo em `TasksView.row(for:completed:)` era um `Image` puro, SEM tap handler — o único caminho de conclusão era o `swipeActions` "Done" trailing (invisível/indescobrível). As linhas não são `NavigationLink` nem tinham `onTapGesture`. **Backend estava SÃO**: `TasksViewModel.complete/reopen` já faziam move otimista + rollback; `geobridge.log` mostrou ZERO POSTs de complete reais (não era rede/bridge, era a UI que nunca disparava). Fix = círculo virou `Button` (label = mesmo SF Symbol), ação ramifica em `completed` (incompleto→`complete` + haptic `.success`; completo→`reopen` + haptic `.light`), `withAnimation(.snappy)` move a linha entre seção aberta e "Completed Today". `.buttonStyle(.borderless)` (load-bearing: impede o List de promover o Button a tap de linha inteira brigando com o swipe), alvo 44pt via `.frame(44×44,.leading)` + `.contentShape(Rectangle())`, cor via token `Color.actionBlue`. Ambos `swipeActions` preservados como power-user. ZERO mudança no ViewModel/bridge.
- **Calibração UX/UI por tela** (tokens existentes só; luz byte-idêntica, só o dark mexeu):
  - **Token B0** — `cardSurface` dark `#1C2536`→`#232E44`: matava elevation-inversion (card quase idêntico ao topo do gradiente sky `#17233B`, podia ler *mais escuro* que o fundo). Um token calibra os 4 lists de uma vez (Today/Tasks/Agents/Settings via `.listRowBackground`).
  - **Tasks** — row `.padding(.vertical,4)`; headers de seção `.subheadline.weight(.semibold)`+`.textCase(nil)` (mata o all-caps grouped shout); first-load `ProgressView` sobre `SkyBackground` (não pisca system bg); error row = `Label(…,"wifi.slash")` + Retry.
  - **Today** — gate de loading (`hasLoaded` no VM) → spinner no sky em vez do falso "Nothing today" durante o 1º fetch; empty-state ganha pull-to-refresh (`GeometryReader`+`ScrollView`+`.refreshable`, minHeight preserva fill).
  - **Chat** — balão assistant `.regularMaterial`→`cardSurface` sólido (legibilidade no dark); cursor pending `systemGray5`→`hazeGrey`; mic button `systemGray6`→`cardSurface`; `.padding(.bottom,8)` no stack (última bolha limpa a input bar). Mata ilhas system-grey.
  - **Agents** — loading no sky; `statusColor("running")` `.blue`→`.actionBlue` (green/red/gray semânticos mantidos); row `.padding(.vertical,2)`→`4`. Console deixado verbatim (superfície terminal intencional).
  - **Settings** — resultado do teste colorido por outcome (`.green`/`.red`); hint de formato de URL movido pro footer da seção (descobrível antes de falhar), não só no path de erro.
- **QA hook `-geoTab`** (`RootView`): `TabView(selection:)` com tabs `.tag`eadas; `initialTab()` lê `UserDefaults.standard.string(forKey:"geoTab")` (só se ∈ `[today,tasks,chat,agents]`, senão `today`), SEM write-back → `simctl launch … -geoTab tasks` injeta no NSArgumentDomain efêmero (só aquele launch), lançamentos normais caem em `today` intocados. Torna o screenshot por-tab scriptável.
- Review adversarial: tap-to-complete/token-discipline/QA-hook/consistência/escopo checados; 1 defeito achado+corrigido (error row do Tasks sem `.listRowBackground(Color.cardSurface)` → card off-token cinza sob `.skyScreen()`). Zero code comments, escopo só `GeoMobile/`, `Shared/Secrets.swift` intocado.
- **Screenshot gate (simulador iPhone 17)**: BUILD SUCCEEDED de primeira; 8 PNGs (`today/tasks/chat/agents` × light/dark) em `/Users/biel/.claude/jobs/d9838200/tmp/shots/`. Todos PASS: dark é night-sky em toda tela, cards visivelmente elevados sobre o gradiente nos 4 lists (fix B0 confirmado), sem system-grey no Chat, Today mostra spinner (não "Nothing today") no 1º load. Zero iterações.
- **Gate final device (2026-07-05)**: `ruby gen_project.rb` + **BUILD SUCCEEDED** no iPhone físico (`-destination 'platform=iOS,id=2C85…'`, team 6RRNRWCXSD, `-allowProvisioningUpdates`). **App instalado** via devicectl — output confirmou `App installed` (bundle `com.gabrielmendonca.geomobile`); **`process launch` OK** (device desbloqueado, app abriu). Bridge NÃO tocado.
- ⏳ Verificação tátil (Gabriel): tocar no círculo marca feito (linha anima pra Completed + haptic), tocar no check reabre; ambos swipes ainda funcionam; alvo 44pt; cards elevados no dark nas 4 telas de lista no aparelho.

# context-scraping · WhatsApp extractor → life-context extractor — 2026-07-05
- Extractor evoluído de "tarefas/fatos/urgente" para **life-context**. Rename `whatsapp-extractor.py → context_scraping.py`; código todo em 1 arquivo (sem novo store persistente), 2 cópias sincronizadas repo↔`~/.hermes/scripts` (md5 idêntico `abb0935c…`). Commit `cfb9296` (sem push).
- **Taxonomia nova**: CLASSIFY (Haiku) ganhou `people`/`social`/`mood`; DECIDE (Sonnet) ganhou `people`/`digest`. FATO ampliado p/ incluir decisão-na-conversa. `mood`≤1, bias forte a vazio, nunca clínico/inferido/sobre-terceiros.
- **Blocos-pessoa com continuidade**: `append_person_continuity()` resolve bloco existente por título EXATO (`_find_person_block` tenta forma-com-espaços ANTES da forma-com-hífen — senão erra todo bloco criado pelo app), sem fuzzy. Seção fenced `<!-- geo:cont -->` dated `§`, cap 8 (evicta mais antigo), dedup por `_norm` (idempotente cross-run), guard `layer:user` (nunca escreve em `Amigos.md` — cria bloco novo review). Sem target → cria bloco novo (mal-menor aceito: pode gerar `Nome-1.md` em runs repetidos).
- **Digest diário**: `upsert_daily_digest()` → `Contexto do dia YYYY-MM-DD.md` (type fleeting/layer review, MOC — Rotina), fences `clima`/`social`/`pessoas`, merge idempotente (clima = last-write só quando há clima; social/pessoas = append-if-absent dedup). `geo_context` pula títulos "Contexto do dia" do brain_context.
- **Clima leve**: uma linha neutra situacional sobre o DIA do Gabriel, ou null. Sem campo de humor por pessoa em NENHUM schema (garantia estrutural anti-vigilância).
- Gate: `py_compile` OK nas 2 cópias; **dry-run ponta-a-ponta verde** (66 records, 3 buckets, 3 with_proposals, 0 errored, 4 calls 13555in/5321out) — `decided` JSON já traz chaves `people`/`digest` (vazias nesta janela = bias correto); watermark intacto (dry-run retorna antes de persist/advance).
- ✅ **RESSALVA RESOLVIDA (mesmo dia, loop worker→verifier→REVISE→worker→ACCEPT)**: watermark de `max(ts)` cru perdia mensagem em colisão de ts (~15% do corpus real colide; 2.947 grupos são msgs genuinamente distintas). Fix: `_advance_watermark` persiste `boundary_msg_ids` (msg_ids no ts de fronteira) e `read_window(watermark, boundary_msg_ids)` filtra `ts <` + (`ts ==` só se msg_id na fronteira). REVISE do verifier pegou 2º defeito real (empate `new_ts == last_ts` não salvava a fronteira → reprocessamento infinito da msg empatada) → fix: branch de empate faz UNION dedupado + save; avanço estrito segue substituindo wholesale. ACCEPT final com repro sintética: colisão não perde, empate não loopa, avanço não regride, state legado compat (reprocessa 1x). Guards `isinstance` nos caminhos novos `people`/`digest` de `persist()` inclusos.
- Ressalva menor remanescente (não-bloqueante): repeat null-target pode gerar blocos duplicados `Nome-N.md`.

# context-scraping v2 · contexto incremental + Opus xhigh + ciclo de vida de tasks — 2026-07-05
- Commit `9c702f6` (só `hermes/scripts/context_scraping.py`, sem push). 2 cópias sincronizadas repo↔`~/.hermes/scripts` (md5 idêntico `1bc157a9…`).
- **Contexto incremental por chat** — novo store `~/.hermes/context_scraping.chats.json` (v1) com um **resumo vivo por chat** (estado durável, não log). `update_chat_summaries()` roda LAZY: só resume chats com mensagens novas nesta janela; chats parados nunca chamam LLM nem entram no DECIDE. Delta por `last_msg_ts` por chat (independente do watermark global). Chat novo (sem entrada) → **bootstrap** automático: `read_full_history()` lê o histórico completo daquele chat (cap `BOOTSTRAP_MAX_MSGS=1500`), fatia em chunks de `BOOTSTRAP_CHUNK_MSGS=250`, fan-out de Haikus sob o semáforo + 1 fold. **Não há flag de bootstrap** — é inline e automático na 1ª vez que um chat é visto. Store poda entradas com `last_msg_ts` > `CHAT_PRUNE_DAYS=90` no save; falha de resumo **segura o watermark** (`advance_ok = advance_ok and summary_ok`), zero perda de mensagem.
- **Custo por run** limitado ao fan-out de LLM: `~2×(#chats ativos)` Haikus de contexto + 1 fan-out único de chunks por chat recém-visto. I/O de jsonl é barato; nada de re-resumir o corpus inteiro por ciclo.
- **DECIDE em Opus xhigh** — modelo `claude-opus-4-8` (override `HERMES_WA_DECIDE_MODEL`), `output_config.effort` **aninhado** = `xhigh` (override `HERMES_WA_DECIDE_EFFORT`), `thinking:{type:adaptive}`, `max_tokens=32000`, timeout `300s`. Fallback p/ Haiku (sem `output_config`/`thinking`) se o Opus indisponível — 1 run degradado em vez de perder a janela. Prompt ganhou seção `CONTEXTO DAS CONVERSAS` (resumos vivos dos chats ativos) e a lista de tasks agora carrega `[id]` p/ dedup e ciclo de vida.
- **`task_updates` com guardrails** — DECIDE pode fechar/arquivar tasks EXISTENTES com evidência explícita (dúvida = não mexe). `apply_task_updates()`: match **só por id exato** (`TASKS_DIR/{id}.json`, nunca fuzzy/título); id validado por regex `[0-9A-Fa-f-]{36}` (mata path traversal — `/`,`..`,`%` rejeitados antes de montar path); cap `MAX_TASK_MUTATIONS=5`; `complete` muta só `status`+`modifiedAt` (demais chaves byte-idênticas, nunca reabre concluída); `delete` = **arquiva** (`os.replace` → `~/.hermes/task_archive/{id}.{stamp}.json` + linha em `archive_log.jsonl`), **nunca `unlink`**. Dry-run só loga `[dry]`, escreve zero.
- Gate (venv hermes, offline, sandbox `$TMPDIR`, sem rede/vault real): `py_compile` OK; testes sintéticos de `apply_task_updates` (traversal bloqueado, complete byte-preserva, delete arquiva sem unlink, cap=5, id inexistente no-op, completed não reverte, non-dict ignorado) todos verdes; `run_whatsapp` monkeypatchado prova watermark+chats NÃO avançam em `summary_ok=False`; body do DECIDE confirma `output_config` aninhado + `thinking` adaptive + fallback limpo; `load_chats`/`save_chats` round-trip + poda 90d. **Dry-run real** (janela alargada 24h/400 records/16 buckets, Opus rodou 58 calls, artefatos reais md5-intactos antes/depois): stdout JSON com `task_updates` presente (`[]` = bias conservador correto). Verifier: ACCEPT.
- **Ressalvas abertas (não-bloqueantes)**: (1) `task_archive/`+`archive_log.jsonl` sem poda → crescem ilimitados (lento, baixa severidade). (2) `persist()` roda antes do gate `advance_ok` (blocos/tasks podem ser escritos em run cujo watermark não avança → dedup do próximo DECIDE cobre em retry sobreposto) — comportamento PRÉ-EXISTENTE, não introduzido nesta v2. (3) shape `output_config.effort`/`thinking:adaptive` é superfície de API interna não documentada, verificada só na construção do request (não live). (4) repeat null-target de blocos-pessoa ainda pode gerar `Nome-N.md` (herdado da v1).

# GeoMobile · Today + Tasks unificados numa tela só — 2026-07-06
- **Unificação Today+Tasks numa única tela** (elimina a aba Tasks). `Features/Today/TodayViewModel.swift` reescrito como VM unificado: mergeia todo o `TasksViewModel` (`overdue`/`today`/`upcoming`/`completedToday`, `complete`/`reopen`/`create(TaskDraft)`, `apply`/`applyPending`/`isDueToday`, mutação otimista + rollback) com a lógica EventKit do `TodayViewModel` antigo (`EventKitService.shared`, `dayInterval` de hoje, auto-reload por `changeToken`, `requestAccess`/`isAuthorized`, e o dedup `mirrorKey` mantido VERBATIM). Novo enum `AgendaEntry` (`.task`/`.event`) + `rebuildAgenda()` privado funde `eventEntries` cacheados com as tasks de hoje pelo sort original (all-day primeiro → hora de início → título).
- **`Features/Today/TodayView.swift`** reescrito como a tela única. Seções topo→base: **Overdue** (header vermelho, task rows), **Today** (`todayAgenda` cronológico misturando task rows completáveis — círculo 44pt com haptic + `withAnimation(.snappy)` + `.buttonStyle(.borderless)` — com event rows read-only reusando o shape do TodayRowView antigo), **Upcoming** (header secundário), **Completed Today** (`DisclosureGroup` colapsado, reopen por checkmark/leading-swipe). Task rows preservam ambos swipeActions; eventos nunca são completáveis. Mantidos: botão `+` na toolbar + `NewTaskSheet` (movido pra cá), `.settingsToolbar()`, pull-to-refresh, spinner de 1º load sobre `SkyBackground` (gate `hasLoaded`), banners de access + erro como `safeAreaInset`, e o card "Nothing today".
- **`RootView.swift`**: tab bar reduzida a 3 abas (Today/Chat/Agents). `initialTab()` valida `today/chat/agents`; `"tasks"` armazenado mapeia pra `"today"` → `-geoTab tasks` dos scripts de QA ainda resolve (alias verificado: `tasks-dark.png` == `today-dark.png` byte-idêntico).
- **Deletados**: `Features/Tasks/TasksView.swift`, `Features/Tasks/TasksViewModel.swift`, diretório `Features/Tasks/` vazio removido. Grep na árvore inteira = zero referências órfãs a `TasksView`/`TasksViewModel`.
- **Gate simulador (iPhone 17)**: BUILD SUCCEEDED de primeira; 8 PNGs (`today/tasks/chat/agents` × light/dark) em `/Users/biel/.claude/jobs/d9838200/tmp/shots-unified/`. QA visual: 0 defeitos atribuíveis à unificação; 3 abas em toda tela; banner "Calendar access needed" é o estado EventKit-não-autorizado do simulador (não defeito).
- **Gate final device (2026-07-06)**: `ruby gen_project.rb` + **BUILD SUCCEEDED** no iPhone físico (`-destination 'platform=iOS,id=2C85…'`, team 6RRNRWCXSD, `-allowProvisioningUpdates`). **App instalado** via devicectl — output confirmou `App installed` (bundle `com.gabrielmendonca.geomobile`). **`process launch` = RequestDenied/Locked** — tela bloqueada, abrir na mão. Bridge NÃO tocado.
- ⏳ Verificação tátil (Gabriel): Today mostra Overdue/Today/Upcoming/Completed numa tela só; eventos do calendário interleavados nas tasks de hoje; tocar círculo marca feito; 3 abas no aparelho.

---

# 2026-07-06 — v3 do pipeline WhatsApp→Geo (mídia)

Fechamento da camada de mídia do pipeline `zap → wa_ingest.jsonl → context_scraping.py → GeoVault`.

## O que entrou
- **Mídia daqui-pra-frente** (forward-only): URLs do Baileys expiram em minutos, sem backfill. Sidecar baixa `image/audio/document` (vídeo excluído por custo/tamanho) para `~/.hermes/wa_media/<msg_id>.<ext>` best-effort, **depois** do append da linha de texto (texto nunca bloqueado/mutado; path determinístico do `msg_id`). Guardrails: cap 20MB (gate declarado + streaming), timeout 15s por download, prune de 60d no start.
- **Whisper local**: `_transcribe_audio` = ffmpeg (16k mono wav) → `whisper-cli` (ggml-large-v3-turbo, pt), `finally` limpa temporários. Timeouts ffmpeg 60s / whisper 300s.
- **Visão Haiku**: `_vision_describe` (imagem→1 frase) e `_pdf_gist` (PDF→1-2 frases) via blocos base64 no `_call_model` generalizado (`content_blocks`). Caps 5MB imagem / 10MB PDF; não-PDF e imagem grande caem em rótulo determinístico `[arquivo: …]`/`[imagem: grande demais]`.
- **Cache dois-níveis**: `_media_memo` em processo + sidecar `<path>.txt` em disco (some junto com a mídia no prune de 60d). Só resultados determinísticos são cacheados; falhas transitórias retornam `""` e NÃO cacheiam (retry no próximo ciclo). Prova: 2ª passada não re-invoca whisper.
- **Guardrails de degradação**: qualquer falha (download pendente, ffmpeg/whisper nonzero, timeout, modelo) → `_media_text=""` e `format_messages` cai no rótulo `[audio]`/`[image]` de antes; run nunca quebra. Mensagens de bootstrap (histórico) não têm `media` → idênticas a hoje.

## Rollout (vivo)
- md5 repo↔`~/.hermes` idêntico nos 2 arquivos antes do deploy (sem rsync necessário).
- Backup: `~/.hermes/whatsapp-ingest/ingest.js.bak.20260706-*`.
- `launchctl kickstart -k gui/501/ai.hermes.whatsapp-ingest` → **state=connected** em <5s, PID 43685 estável em 2 leituras a 22s, `attempt=0`/`reconnects=0` (sem crash-loop), heartbeat avançando. `~/.hermes/wa_media/` presente. Reconciliação Fase-0 preservou hardening vivo (lock/status/backoff/notify).

## Ressalvas abertas
- Validação tátil pendente: mandar um áudio/imagem/PDF de teste no WhatsApp e confirmar `wa_media/<id>.<ext>` + `<id>.<ext>.txt` + texto derivado no próximo ciclo do cron.
- Sem fallback determinístico específico se a chamada de visão/PDF falhar por motivo estrutural (degrada pro rótulo genérico; blast radius limitado à janela de overlap, sem loop infinito).
