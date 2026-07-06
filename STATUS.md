# STATUS — Geo

Histórico anterior (era do app macOS + migração Obsidian, jan–jul/2026): `docs/archive/STATUS-2026H1-pre-obsidian.md`.

## Estado atual (2026-07-06)

- **Vault**: `~/GeoVault/` (Obsidian) é a fonte de verdade desde 04/07. App macOS aposentado e removido do repo (histórico git preserva). Vault antigo em `~/Library/Application Support/Geo/` = backup congelado.
- **Indexador**: `hermes/scripts/geo_indexer.py` → `Index/blocks.sqlite`; ignora `.sync-conflict-*`.
- **hermes**: base upstream v0.18.0 + main `76a468e5`; patches em `hermes/PATCHES.md`. Chat lane gpt-5.5/openai-codex, pesado via cc-dispatch.
- **WhatsApp→Geo**: `context_scraping.py` v2 (contexto incremental por chat + DECIDE Opus xhigh + ciclo de vida de tasks) + v3 mídia no sidecar (whisper local, visão Haiku, PDF, cache 2 níveis). Vivo, watermark com boundary_msg_ids.
- **GeoMobile**: 3 abas (Today unificado com agenda EventKit intercalada / Chat / Agents) + Terminal multi-tab; instalado no iPhone físico.
- **GeoBridge**: `ai.geo.bridge` vivo, HTTPS via tailscale serve; contrato em `GeoBridge/CONTRACT.md`.
- **GeoCalendar / GeoCapture**: daemons vivos (task→EKEvent 4 calendários; screenshot+OCR→Captures/).

## Limpeza 2026-07-06

- Backlog não-commitado consolidado (5 commits: repoint vault, fix indexer, módulos novos, GeoMobile completo).
- Removidos do repo: app macOS (`Geo/` + `Geo.xcodeproj`), `conductor/`, `INSTALL.md`, `.github/workflows/release.yml` (CI de notarização do app), `tools/` vazio. Artefatos locais apagados: `build/` 1.2G, `GeoCore/.build` 304M, `default.profraw`, `.DS_Store`.
- Docs reescritos pra realidade pós-Obsidian: `README.md`, `CLAUDE.md`; `GeoBridge/CONTRACT.md` corrigido (default `GEO_TASKS_DIR` → `~/GeoVault/Tasks`).

## Pendências vivas

- Verificação tátil GeoMobile (Today unificado) + teste de mídia WhatsApp (v3) — **com outro agente**.
- F2 da migração: bridge na VM + Syncthing (parcial; sync-conflict já mitigado com maxConflicts=0 + filtro + rescan 300s).
- Ressalvas conhecidas do context_scraping: `task_archive/` sem poda; repeat null-target pode gerar blocos `Nome-N.md`.

# 2026-07-06 — claude-brain no vault + clipboard 2 fases no geocapture
- **Bancada geo-claude MIGRADA pra dentro do vault**: `.claude/` (hook geo_context, /pensar /ideia /aprofundar, @brain-researcher, settings) + `CLAUDE.md` novo em `~/GeoVault/`; comando novo **`claude-brain`** (/opt/homebrew/bin, cd no vault + Soul injetado; `--add-dir` dispensado). `~/geo-claude` e `geo-claude-brain` removidos; scripts soltos arquivados em `~/Lab/geo-claude-scripts`. `.claude` e `/CLAUDE.md` no `.stignore` (não syncam pra VM).
- **geocapture clipboard 2 fases**: imagem no clipboard IMEDIATA (fase 1, antes do OCR), payload completo (imagem+OCR+fileURL) depois — só sobrescreve se `changeCount` não mudou (cópia do usuário durante OCR vence). Poll 5s→1s.
- **ROOT CAUSE pipeline morto desde 05/07**: TCC do Desktop negado (Cocoa 256; binário novo trava em `open()` síncrono no consent sem UI — launchd). Fix permanente: screenshots movidos pra `~/Screenshots` (sem TCC) via as 3 chaves `com.apple.screencapture`; daemon nem toca mais no Desktop. Captures de 05-06/07 perdidos (janela morta).
- Gate: e2e real — cp de png com texto em `~/Screenshots` → "clipboard primed (image only)" + par `.png`+`.md` no vault + `pbpaste` = texto do OCR + `clipboard info` = TIFF/PNG/furl/utf8.
