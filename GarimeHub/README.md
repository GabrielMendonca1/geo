# Garime Hub

App local de menu bar para **Print → clipboard** e **ditado Whisper (⌥Space)**.
Bundle `ai.garime.hub`, instalado em `~/Applications/Garime Hub.app`. Entradas e dependências: [`MAP.md`](MAP.md).

- **Print:** observa via FSEvents a pasta configurada em `com.apple.screencapture location` (fallback: Mesa). Novos screenshots completos são copiados para o clipboard; o arquivo permanece na pasta.
- **Ditado:** ⌥Space inicia; ⌥Space para e transcreve. Streaming com `WindowedDecoder`/`DictationSession`, texto no app em foco por `Typist`/`Paster`, fallback em lote por `Transcriber`. Durante transcrição, ⌥Space cancela; tokens de geração impedem entrega tardia.
- **Feedback:** ícone triangular animado por estado e nível real do microfone, respeitando Reduce Motion. Sons sintetizados localmente, volume/toggle persistentes em `ai.garime.hub.feedback.*`. O gate de captura interrompe e bloqueia playback durante o ditado; o som inicial é omitido para não contaminar a gravação.
- **Cartão:** estado do ditado, Ditar, Sons…, Sair. Clique direito abre o menu; sem Acessibilidade, ele oferece “Ativar colagem automática…”.

Sem SSH, gravação de reuniões/calls, bloqueio de sono, tarefas, conversões ou Serviços do Finder. O app não acessa a rede.

## Build, testes e instalação

```bash
./build.sh
./smoke.sh
./Tests/Feedback/run.sh
./Tests/FeedbackIntegration/run.sh
./Tests/Soak/run.sh 4
./install.sh
```

`build.sh` compila recursivamente `Sources/**/*.swift` com `swiftc` e assina com a primeira identidade Apple Development/Developer ID disponível. Sem identidade, usa ad-hoc e avisa que grants TCC podem ser perdidos. Não há projeto Xcode.

`smoke.sh` verifica bundle, processos isolados, transcrição real, timeout/cancelamento, unidades, decoder, ícone e feedback. Não valida microfone nem colagem física (TCC): para isso, teste manualmente ⌥Space no TextEdit. `bench.sh <audio>` mede o streaming; `perf.sh` mede footprint, wakeups e leaks.

`install.sh` recompila, para o agente/app existente, substitui `~/Applications/Garime Hub.app`, atualiza LaunchServices/Services e escreve `~/Library/LaunchAgents/ai.garime.hub.plist`. Não usa sudo. Logs: `~/Library/Logs/garime/garimehub.{out,err}`. `KeepAlive=false`: Sair encerra de verdade.

`migrate.sh` é apenas a migração opcional do antigo bundle Garime Whisper: faz backup, copia ajustes de Sons e chama o instalador. Não é necessário para atualizar um Hub já instalado.

## Dependências

| O quê | Caminho |
|---|---|
| whisper.cpp CLI | `/opt/homebrew/bin/whisper-cli` |
| modelo | `~/.cache/whisper/ggml-large-v3-turbo.bin` |
| ffmpeg | `/opt/homebrew/bin/ffmpeg` |

Microfone e Acessibilidade são permissões do macOS. Sem Acessibilidade ou com entrada segura, o texto fica no clipboard em vez de sintetizar colagem. Entrada segura marca o texto como oculto para gerenciadores de clipboard. O clipboard anterior à colagem é restaurado após ~800 ms somente se ninguém o alterou. Enter nunca é enviado.

Gravação para automaticamente em 120 s; capturas menores que 0,4 s são descartadas. Áudio temporário é apagado ao finalizar. Transcrição em lote tem watchdog de 180 s; cancelamento encerra os subprocessos.

## Layout

```
Sources/App/            main, AppDelegate, Config
Sources/Audio/          Recorder, LevelMeter, StreamBuffer, FlushGuard
Sources/Transcribe/     Transcriber, WhisperBackend, WindowedDecoder, Stabilizer, TextChunker
Sources/Dictation/      DictationSession, Hotkey, Paster, Typist, FocusAnchor
Sources/System/         ProcessRunner, PathWatcher
Sources/UI/             StatusIcon, IconAnimation, DotMatrix, HubPanel, MenuController
Sources/Integrations/   ScreenshotClipboard
Sources/Feedback/       síntese, playback, política e ajustes
Tests/<Suite>/          harnesses existentes
```

A remoção dos recursos antigos não apaga gravações, caches, preferências ou regras sudoers preexistentes. Serviços antigos podem permanecer no cache do Finder até ele atualizar sua lista; o bundle atual não publica `NSServices`.
