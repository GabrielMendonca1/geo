# Ponto do Projeto Magnum

## Bibliotecas e Frameworks Usados

### Linguagem e base
- Swift 5.9+ (app macOS nativo)
- SwiftUI (UI declarativa)
- AppKit/Cocoa (integracao nativa com janelas, menu bar e eventos do sistema)

### Frameworks Apple usados no codigo
- Foundation, Combine
- Vision (OCR)
- UserNotifications (notificacoes locais)
- CoreGraphics + ApplicationServices (event taps e input global)
- CoreServices (FSEvents para watch de arquivos)
- UniformTypeIdentifiers (clipboard, drag-and-drop e export)
- AVFoundation (suporte de midia em historico)
- Charts (graficos no modulo de custos)
- CoreText, OSLog

### Dependencias externas (Swift Package Manager)
- GRDB (SQLite + FTS para indexacao e busca)
- swift-markdown (produto `Markdown`, parser/estilizacao markdown)

## Logica e Arquitetura Usada

### Arquitetura geral
- Estilo store-driven (proximo de MVVM), com camadas claras:
  - `Views`: interface e fluxo das telas
  - `Stores`: estado global e persistencia do dominio
  - `Services`: integracoes com sistema e regras transversais
  - `Models`: entidades e tipos de negocio
  - `Utilities`/`Extensions`: helpers e utilitarios
- Estado compartilhado com singletons `shared` + `ObservableObject`, injetados em `@EnvironmentObject` no `MagnumApp`.

### Persistencia
- Blocos: arquivos `.md` em `Application Support/Magnum/Blocks` (fonte de verdade).
- Busca/index: SQLite em `Magnum/Index/blocks.sqlite` via `DatabaseService` + `IndexCoordinator`.
- Outros dominios em JSON:
  - tarefas: `Magnum/Tasks/*.json`
  - tags: `Magnum/tags.json`
  - dias: `Magnum/days.json`
  - custos: `Magnum/Costs/costs.json`
  - historico de capturas: `Magnum/capture-history.json`

### Fluxos principais
1. Captura e OCR:
   - `ScreenshotWatcher` detecta screenshot novo.
   - `OCRService` extrai texto com Vision.
   - resultado vai para clipboard e `LogStore`.
2. Hotkeys globais:
   - `GlobalHotkeyManager` intercepta atalhos (event tap) e dispara acoes (colar OCR, abrir Agent, quick history).
3. Blocos Markdown:
   - `BlocksStore` cria/edita/exclui arquivos `.md`.
   - `MarkdownConverter` e `MarkdownIndexingService` extraem estrutura/metadados.
   - `IndexCoordinator` atualiza indice SQLite.
4. Tarefas e notificacoes:
   - `TasksStore` gerencia agenda, recorrencia e snooze.
   - `NotificationManager` monitora tarefas pendentes e envia notificacoes locais.

### Organizacao da UI
- Entrada principal: `App/MagnumApp.swift`.
- Navegacao por abas em `NavigationStore` + `AppTab`.
- Panes: Home, Tasks, History, Blocks, Costs e Agent.
- Janelas auxiliares: menu bar extra, floating shelf, editor dedicado, settings e about.
