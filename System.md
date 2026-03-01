# System - Diretorio e Funcao dos Arquivos

## Localizacao
- Raiz: `/Users/biel/Programming/magnum`
- Codigo principal: `/Users/biel/Programming/magnum/magnum`

## Diretorio desenhado (visao geral)

```text
/Users/biel/Programming/magnum
├── Magnum.xcodeproj
├── Ponto.md
├── System.md
└── magnum
    ├── App
    ├── Extensions
    ├── Models
    ├── Services
    ├── Stores
    ├── Utilities
    ├── Views
    ├── Resources
    ├── scripts
    └── conductor
```

## Magnum.xcodeproj
- `Magnum.xcodeproj/project.pbxproj`: configuracao do target, arquivos do app e dependencias SPM (`GRDB`, `swift-markdown`).

## magnum/App
- `App/Info.plist`: metadados e configuracoes base do app.
- `App/Magnum.entitlements`: capacidades/sandbox/permissoes declaradas.
- `App/MagnumApp.swift`: entrada do app; injeta stores/services; define janelas, comandos e menu bar extra.

## magnum/Extensions
- `Extensions/Bundle+Copyright.swift`: helper para ler copyright do bundle.
- `Extensions/Bundle+Name.swift`: helper para ler nome do app do bundle.
- `Extensions/Bundle+Version.swift`: helper para ler versao/build do bundle.
- `Extensions/NSWindow+AlwaysOnTop.swift`: extensoes de janela para modo always-on-top.

## magnum/Models
- `Models/AppTheme.swift`: enum de temas e chave de persistencia do tema.
- `Models/CalendarEvent.swift`: modelo de eventos exibidos no calendario.
- `Models/Day.swift`: modelo de dia (ids de blocos/capturas por data).
- `Models/EditorTypographyPreferences.swift`: presets e regras tipograficas do editor.
- `Models/Holiday.swift`: modelos de feriado e pais/regiao.
- `Models/ShelfItem.swift`: item mostrado no floating shelf.
- `Models/Tag.swift`: modelo de tag, cor e erros de validacao de tag.
- `Models/TaskItem.swift`: modelo de tarefa, status, lembretes e recorrencia.
- `Models/ThemePalette.swift`: paleta visual por tema.

## magnum/Services
- `Services/CursorShakeDetector.swift`: detecta gesto de "sacudir cursor" para abrir shelf.
- `Services/DatabaseService.swift`: camada SQLite/GRDB (schema, migracao, upsert, busca, FTS).
- `Services/DayManager.swift`: gerencia dia corrente e vinculos bloco/captura com DayStore.
- `Services/FileWatcherService.swift`: watcher de arquivos com FSEvents.
- `Services/FontManager.swift`: registro e utilitarios de fontes do app/editor.
- `Services/GlobalHotkeyManager.swift`: atalho global e event tap (colar captura, abrir agent, quick history).
- `Services/HolidayService.swift`: calcula feriados/eventos de calendario.
- `Services/IndexCoordinator.swift`: sincroniza `BlocksStore` com indice SQL de busca.
- `Services/NotificationManager.swift`: monitora tarefas e dispara notificacoes locais.
- `Services/OCRService.swift`: OCR de imagens via Vision.
- `Services/ScreenshotWatcher.swift`: observa pasta de screenshots, processa imagem e atualiza clipboard/log.
- `Services/ThemeManager.swift`: estado global do tema e aplicacao de aparencia.

### magnum/Services/Markdown
- `Services/Markdown/InlineImageLoader.swift`: resolve/carrega imagens inline em markdown.
- `Services/Markdown/MarkdownConverter.swift`: parse/render de frontmatter + corpo markdown.
- `Services/Markdown/MarkdownIndexingService.swift`: extrai tags, contadores de tarefas e metadados para indexacao.
- `Services/Markdown/MarkdownStyler.swift`: cria ranges de estilo para renderizacao markdown rica.
- `Services/Markdown/SyntaxHighlighter.swift`: destaque de sintaxe para trechos de codigo.

### magnum/Services/Migration
- `Services/Migration/DayMigrationService.swift`: migracao de dados antigos de dia.
- `Services/Migration/StorageMigrationService.swift`: migracao de storage de blocos/metadata.
- `Services/Migration/TaskMigrationService.swift`: migracao de dados antigos de tarefas.

### magnum/Services/Permissions
- `Services/Permissions/Permission.swift`: protocolo base e estado de permissao.
- `Services/Permissions/AccessibilityPermission.swift`: implementacao de permissao de acessibilidade.
- `Services/Permissions/InputMonitoringPermission.swift`: implementacao de permissao de monitoramento de input.
- `Services/Permissions/PermissionCache.swift`: cache local do estado de permissoes.
- `Services/Permissions/PermissionRegistry.swift`: orquestrador central das permissoes do app.

## magnum/Stores
- `Stores/BlocksStore.swift`: CRUD de blocos markdown; metadata; file watch; disparo de indexacao.
- `Stores/CostsStore.swift`: dominio financeiro (fixos/transacoes/workspaces) e persistencia em JSON.
- `Stores/DayStore.swift`: persistencia e consulta de dias (`days.json`).
- `Stores/LogStore.swift`: historico de capturas OCR/imagem, cache de preview e persistencia.
- `Stores/NavigationStore.swift`: aba selecionada e navegacao para historico.
- `Stores/ShelfStore.swift`: estado dos itens do floating shelf.
- `Stores/TagStore.swift`: CRUD de tags com persistencia em JSON.
- `Stores/TasksStore.swift`: CRUD de tarefas, recorrencia e persistencia por arquivo JSON.

## magnum/Utilities
- `Utilities/ClipboardWriter.swift`: escreve payloads (texto/imagem/arquivo) no clipboard.
- `Utilities/MagnumStyle.swift`: design tokens e componentes visuais utilitarios.
- `Utilities/ResponsiveLayout.swift`: helpers de layout responsivo por tamanho.
- `Utilities/WindowReflection.swift`: ponte SwiftUI -> NSWindow para customizacao de janela.

## magnum/Views
- `Views/MainView.swift`: container principal da janela; aplica tema, title bar e permissoes.

### magnum/Views/About
- `Views/About/AboutCommand.swift`: comando de menu para abrir About.
- `Views/About/AboutView.swift`: conteudo da tela About.
- `Views/About/AboutWindow.swift`: janela nativa da tela About.

#### magnum/Views/About/Attributions
- `Views/About/Attributions/AttributionsView.swift`: tela de creditos/atribuicoes.
- `Views/About/Attributions/AttributionsWindow.swift`: janela nativa de atribuicoes.

### magnum/Views/Calendar
- `Views/Calendar/CalendarDayCell.swift`: celula de dia no grid mensal.
- `Views/Calendar/CalendarEventPill.swift`: pill visual de evento.
- `Views/Calendar/CalendarGrid.swift`: grade mensal de dias.
- `Views/Calendar/CalendarHeader.swift`: cabecalho do calendario.
- `Views/Calendar/CalendarSidebar.swift`: barra lateral do dia selecionado.
- `Views/Calendar/CalendarWeekdayHeader.swift`: cabecalho de dias da semana.
- `Views/Calendar/MonthCalendarView.swift`: composicao da visao mensal e posicionamento de eventos.

### magnum/Views/Commands
- `Views/Commands/MyCommands.swift`: atalhos/comandos principais de navegacao por abas.

### magnum/Views/Components/Editor
- `Views/Components/Editor/LinkEditorViewController.swift`: editor nativo para links no markdown.
- `Views/Components/Editor/MagnumMarkdownEditor.swift`: wrapper SwiftUI do editor AppKit.
- `Views/Components/Editor/MarkdownNSTextView.swift`: comportamento de edicao (listas, tabelas, comandos, atalhos).
- `Views/Components/Editor/MarkdownTextStorage.swift`: engine de texto rico/estilizacao incremental.
- `Views/Components/Editor/SlashCommandViewController.swift`: menu de slash commands.

### magnum/Views/Export
- `Views/Export/ExportCommands.swift`: comando de exportacao.
- `Views/Export/MyExportDocument.swift`: estrutura de documento para export de dados.

### magnum/Views/FloatingShelf
- `Views/FloatingShelf/FloatingShelfManager.swift`: ciclo de vida do shelf e acao por gesto.
- `Views/FloatingShelf/FloatingShelfView.swift`: UI do shelf com drag-and-drop.
- `Views/FloatingShelf/FloatingShelfWindow.swift`: janela/painel flutuante do shelf.

### magnum/Views/MenuBar
- `Views/MenuBar/MenuBarPopup.swift`: popup do menu bar extra com acoes rapidas.

### magnum/Views/Navigation
- `Views/Navigation/NavigationSegmentedControl.swift`: controle visual de abas na title bar.
- `Views/Navigation/UnifiedNavigationContainer.swift`: roteador de tab atual para pane destino.

### magnum/Views/Panes
- `Views/Panes/AgentPane.swift`: pane do modo agent.
- `Views/Panes/AttachmentHandler.swift`: importacao de anexos e geracao de markdown de arquivo/imagem.
- `Views/Panes/BlockEditor.swift`: editor principal de bloco.
- `Views/Panes/BlocksPane.swift`: lista/acoes de blocos.
- `Views/Panes/HistoryPane.swift`: historico de capturas OCR/imagem.
- `Views/Panes/HomePane.swift`: tela Home (calendario + sidebar de dia).
- `Views/Panes/TaskFormView.swift`: formulario de criar/editar tarefa.
- `Views/Panes/TasksPane.swift`: lista de tarefas com ordenacao/drag.

#### magnum/Views/Panes/Costs
- `Views/Panes/Costs/CostsDonutChart.swift`: grafico donut de custos/receitas.
- `Views/Panes/Costs/CostsPane.swift`: container da area de custos.
- `Views/Panes/Costs/FixedItemFormSheet.swift`: formulario de item fixo.
- `Views/Panes/Costs/FixedItemsList.swift`: lista de itens fixos.
- `Views/Panes/Costs/TagManagementSheet.swift`: gestao de tags financeiras.
- `Views/Panes/Costs/TransactionFormSheet.swift`: formulario de transacao variavel.
- `Views/Panes/Costs/TransactionsList.swift`: lista de transacoes.
- `Views/Panes/Costs/WorkspaceFormSheet.swift`: formulario de workspace financeiro.

#### magnum/Views/Panes/Home
- `Views/Panes/Home/ArtifactRows.swift`: linhas de artefatos (bloco/captura) por dia.
- `Views/Panes/Home/CurrentDayHeader.swift`: cabecalho de dia atual/ano.
- `Views/Panes/Home/DayRow.swift`: linha visual de um dia.
- `Views/Panes/Home/TimelinePopoverView.swift`: popover com timeline de itens do dia.

#### magnum/Views/Panes/PaneShared
- `Views/Panes/PaneShared/Pane.swift`: layout base reutilizavel para panes.

### magnum/Views/Settings
- `Views/Settings/GeneralSettingsView.swift`: preferencias gerais (permissoes, notificacoes, comportamento).
- `Views/Settings/SettingsWindow.swift`: janela de settings e suas abas.

### magnum/Views/SharedViews
- `Views/SharedViews/AlwaysOnTop.swift`: componentes para fixar janela acima das demais.
- `Views/SharedViews/TrafficLightsView.swift`: botoes de title bar customizados.

#### magnum/Views/SharedViews/FAB
- `Views/SharedViews/FAB/FABAction.swift`: botao/acao individual do FAB.
- `Views/SharedViews/FAB/FABConfiguration.swift`: configuracao de acoes do FAB.
- `Views/SharedViews/FAB/FABMenu.swift`: menu FAB completo.

### magnum/Views/Sidebar
- `Views/Sidebar/AppTab.swift`: enum de abas, icones, atalhos e roteamento para cada pane.

## magnum/Resources
- `Resources/Assets.xcassets/*`: assets visuais (icones, cores, menu bar icon).
- `Resources/Fonts/Inter-Regular.ttf`: fonte principal regular.
- `Resources/Fonts/Inter-SemiBold.ttf`: fonte principal semibold.
- `Resources/Fonts/JetBrainsMono-Regular.ttf`: fonte mono para codigo/editor.
- `Resources/Preview Content/*`: assets para previews.

## magnum/scripts
- `scripts/build_dist.sh`: build de distribuicao e empacotamento.
- `scripts/assets/dmg-background.png`: fundo PNG do instalador DMG.
- `scripts/assets/dmg-background.svg`: fonte SVG do fundo do DMG.

## magnum/conductor (documentacao de produto/processo)
- `conductor/product.md`: visao de produto e proposta de valor.
- `conductor/product-guidelines.md`: diretrizes de produto/UX.
- `conductor/tech-stack.md`: stack tecnico oficial.
- `conductor/workflow.md`: fluxo de trabalho do projeto.
- `conductor/tracks.md`: indice de tracks.
- `conductor/setup_state.json`: estado de setup do conductor.
- `conductor/code_styleguides/general.md`: guia de estilo geral.
- `conductor/tracks/cleanup_warnings_20260118/spec.md`: especificacao da track de limpeza de warnings.
- `conductor/tracks/cleanup_warnings_20260118/plan.md`: plano da track de limpeza de warnings.
- `conductor/tracks/cleanup_warnings_20260118/index.md`: indice/resumo da track de limpeza de warnings.
- `conductor/tracks/cleanup_warnings_20260118/metadata.json`: metadados da track de limpeza de warnings.
- `conductor/tracks/header_styling_20260122/spec.md`: especificacao da track de header styling.
- `conductor/tracks/header_styling_20260122/plan.md`: plano da track de header styling.
- `conductor/tracks/header_styling_20260122/index.md`: indice/resumo da track de header styling.
- `conductor/tracks/header_styling_20260122/metadata.json`: metadados da track de header styling.

## Outros arquivos relevantes
- `CLAUDE.md`: instrucoes internas do projeto para agentes/ferramentas.
- `image.png`: imagem de apoio no repositorio.
