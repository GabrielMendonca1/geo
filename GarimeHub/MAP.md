# Mapa do Garime Hub

Um ícone na barra de menu. Clique esquerdo abre o cartão (`HubPanel`); clique direito abre o menu (`MenuController`).
Bundle `ai.garime.hub`, LaunchAgent `ai.garime.hub`, logs em `~/Library/Logs/garime/garimehub.{out,err}`.

| Função | Gatilho | Entrada no código | Depende de |
|---|---|---|---|
| Ditado — fala vira texto no app em foco, streaming | ⌥Space | `AppDelegate.toggle()` → `WindowedDecoder` + `DictationSession` → `Typist`/`Paster` | `whisper-cli`, `ffmpeg`, `~/.cache/whisper/ggml-large-v3-turbo.bin`, Microfone, Acessibilidade |
| Reunião — grava o mic, transcreve no fim | menu / cartão | `MeetingController.begin()` → `MeetingArchive.produce` (`-mc 0`, `.txt` + `.srt`) | `~/Recordings/<stamp>-reuniao/` |
| Call — mic + áudio do sistema | menu | `CallController.begin()` → `rec.sh` do `/record`; estado por FSEvents em `rec.state` | `~/Garime/brain/skills/record/scripts/rec.sh`, BlackHole |
| Manter acordado | Caps Lock ligado, gravação ativa ou toggle | `InsomniaController.hold()`, `CapsWatcher` | `IOPMAssertion`; tampa fechada via `/etc/sudoers.d/garime-whisper` |
| Tarefas do Vault | abrir menu/cartão | `TasksController.refreshIfStale()` | `ssh garime`, cache em `…/Garime/Hub/` |
| Arquivos — converter e ferramentas por roda radial | ⌃⌥Space / ⇧⌃⌥Space com arquivos selecionados | `FilesController.invokeSelection` → `FileToolsBackend` | ffmpeg/ffprobe, cwebp, poppler, gs; Automação → Finder |
| Sons | automático; menu "Sons…" | `SoundFeedback.play` | defaults `ai.garime.hub.feedback.*` |

## O que roda com o app parado

| O quê | Frequência |
|---|---|
| Checagem de heartbeat parado do Capture | 60 s, tolerância 10 s |
| Liveness da call | 60 s, **só enquanto uma call grava** |
| `CapsWatcher` | monitor de `flagsChanged` + 30 s |
| Ícone | sem timer parado; anima só gravando/transcrevendo |

Medido com `./perf.sh`: 14 MB de footprint, 0,2–0,3 idle wakeups/s, 0 leaks (antes: 33 MB, ~6,5/s).

## Não é o app

`whisper-cli`, `~/.cache/whisper/`, `WhisperBackend` e `rec.state` são a ferramenta de transcrição e mantêm o nome.

Prints: o macOS salva direto em `~/Pictures/SCREENSHOT`. O GarimeCapture (OCR) foi aposentado em 2026-10-14.
