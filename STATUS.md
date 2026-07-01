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
