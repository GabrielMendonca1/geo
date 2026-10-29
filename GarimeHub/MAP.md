# Mapa do Garime Hub

Um ícone na barra de menu. Clique esquerdo abre o cartão (`HubPanel`): estado do ditado, Ditar, Sons…, Sair. Clique direito abre o menu (`MenuController`), com acesso aos ajustes de Acessibilidade quando necessário.
Bundle `ai.garime.hub`, LaunchAgent `ai.garime.hub`, logs em `~/Library/Logs/garime/garimehub.{out,err}`.

| Função | Gatilho | Entrada no código | Depende de |
|---|---|---|---|
| Print → clipboard | print novo do macOS | `ScreenshotClipboard` → `PathWatcher` (FSEvents na pasta de prints) | `com.apple.screencapture location` |
| Ditado — fala vira texto no app em foco, streaming | ⌥Space | `AppDelegate.toggle()` → `WindowedDecoder` + `DictationSession` → `Typist`/`Paster`; fallback `Transcriber` | `whisper-cli`, `ffmpeg`, `~/.cache/whisper/ggml-large-v3-turbo.bin`, Microfone, Acessibilidade |
| Sons e ícone/animação | automático; menu/cartão “Sons…” | `SoundFeedback`, `StatusIcon`, `IconAnimation`, `DotMatrix`, `LevelMeter` | defaults `ai.garime.hub.feedback.*`; Reduce Motion do macOS |

O ícone não tem timer parado; anima enquanto prepara, grava ou transcreve. O feedback sonoro é bloqueado durante a captura do microfone.

Prints: o macOS salva direto em `~/Pictures/SCREENSHOT`; o app observa a pasta configurada e copia novos prints para o clipboard.

Reunião, Call, Manter acordado, Tarefas do Vault e Arquivos removidas em 2026-10-14; histórico git a partir de `da8c1ca3`.
