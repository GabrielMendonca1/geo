# Garime Hub

The Garime **menu-bar hub** for the Mac (formerly *Garime Whisper*): one icon, one menu, no Dock. It grew out
of the dictation app and now concentrates everything the menu bar needs to say. Bundle `ai.garime.hub`,
installed at `~/Applications/Garime Hub.app`. Map of every feature: [`MAP.md`](MAP.md).

| Section | What | How |
|---|---|---|
| Ditado | **⌥Space**, speak, **⌥Space** — transcribed locally, typed/pasted into the focused input | native (`whisper-cli` streaming + batch) |
| Reunião | start/stop from the menu → `~/Recordings/<stamp>-reuniao/` with `audio.wav` + `transcript.txt` | native `Recorder` + `whisper-cli` |
| Call | start/stop the `/record` skill's `rec.sh` (BlackHole mix); recordings started from the terminal show up too, mirrored from `~/.cache/whisper/rec.state` | subprocess, `env` with a homebrew PATH |
| Manter acordado | **Caps Lock on = the Mac never sleeps** (the capsomnia contract), plus an automatic hold while any recording runs; the menu toggle is only for holding it by hand | native `IOPMAssertion` stacked over named holds, no `caffeinate` |
| Tarefas | open Vault tasks, read-only, refreshed lazily over `ssh garime` when the hub/menu opens, offline cache with an age stamp | `ssh` BatchMode + cache in `~/Library/Application Support/Garime/Hub/` |
| Arquivos | select files in Finder/Mesa, **⌃⌥Space** converts, **⇧⌃⌥Space** tools — a radial wheel at the cursor | native backend + ffmpeg/poppler/gs |

The icon carries state: a filled triangle (idle), an animated triangular matrix (dictating,
meeting/call and transcribing), and a moon overlay while insomnia is on. Prints are left to macOS (saved to
`~/Pictures/SCREENSHOT`); the GarimeCapture daemon was retired on 2026-10-14.

Dictation, meetings and OCR never leave the Mac. The only network touch is the read-only `ssh`
fetch of Vault tasks over the tailnet.

## Arquivos (antes Tangerine)

O menu de contexto oferece **Arquivos — seleção ⌃⌥Space / ⇧⌃⌥Space e permissões…** e **Sons…**. Os módulos são locais; não substituem ditado, reuniões, calls ou tarefas.

- **Arquivos — fluxo principal: seleção + atalho.** Selecione arquivo(s) no Finder/Mesa e pressione **Control+Option+Space** para conversões ou **Shift+Control+Option+Space** para ferramentas. Clique na operação da roda única temporária junto ao cursor; sem arrastar/importar/abrir dashboard. Setas/Enter e Esc também tratados no painel. **Option+Space continua ditado.** Parâmetros necessários usam editor compacto só após escolher a ação. Saídas novas em `<nome>-result[-N]/`, sem sobrescrever originais. Implementação independente, não inclui aplicativo comercial.
- **Botão direito no Finder:** selecione arquivo(s) › botão direito › **Converter com Garime…** ou **Ferramentas do Garime…** (macOS Services; aparece direto no menu ou em Serviços/Ações Rápidas). Abre a mesma roda junto ao cursor com os arquivos que o Finder entregou, sem precisar de Automação. `install.sh` registra os serviços (`lsregister` + `pbs -update`).
- **Seleção e permissões:** Finder/Mesa usa **Automação → Finder**, solicitada pelo botão explícito do aviso ou menu de seleção. Outros apps requerem Acessibilidade e precisam expor seleção com URLs locais; não há suporte universal. Documento ativo não substitui seleção. Sem clipboard/Cmd+C, varredura de textos privados ou seleção em cache. Revalida seleção/fonte antes de executar; erro, timeout, mudança de app ou seleção incompatível não executam nada. URLs remotas e links simbólicos são recusados; arquivos e pastas protegidos exigem consentimento normal do macOS.
- **Aceite real pendente:** build instalado 20260912.1; os testes cobrem atalhos, resolução injetada, clique e conversão real, mas não substituem Finder→atalho físico→roda→clique. Automação deste runtime está sem AX/PostEvent; nenhuma permissão foi contornada. Teclado do painel, telas/Spaces e movimento físico da tampa precisam de validação interativa. O arraste com Shift foi removido (custava um timer de 20 Hz e monitores globais com o app parado); o painel utilitário foi removido (2026-10-15).
- Imagens: PNG/JPG/WEBP/HEIC/TIFF/PDF/DOCX, compressão, metadados, crop e QR; DOCX incorpora imagem, sem OCR. SVG foi bloqueado explicitamente até haver um renderizador com isolamento seguro. Vídeo/áudio: conversão, compressão, metadados, mute/trim/crop/speed/snapshot/split/normalize/channels conforme família. PDF: texto/imagens/DOCX textual, split, metadados e QR. Archives: ZIP/TAR/GZIP e extração com snapshot privado, rejeição de links/traversal/tipos especiais e limites. MOV e GIF→vídeo também disponíveis.
- **Combinar:** selecione 2+ arquivos e use o grupo Combinar: collage de imagens (grid/linha/coluna/featured, espaço/margem/fundo/ordem), imagens→PDF, merge de PDFs e concatenação de áudio/vídeo. Uma operação por conjunto ordenado. TXT UTF-8 exporta PDF/PNG/JPG paginados. Compressão PDF usa Ghostscript externo (`brew install ghostscript`, AGPL; não redistribuído no bundle).
- **Sons…:** feedback ORIGINAL sintetizado em memória, sem copiar áudio proprietário. Mudança real de setor, confirmação e conclusão/erro/cancelamento; toggle e volume persistentes em `ai.garime.hub.feedback.*`. Volume padrão baixo, rate-limit/coalescing. Captura fecha o gate e para playback antes do mic; cue inicial omitido conservadoramente. Cauda física do HAL e gravação externa iniciada simultaneamente não são garantias de isolamento acústico: valide com seu dispositivo/rota. Áudio desativado não impede funções.
- **Limites explícitos:** RAR encode depende de encoder/licença local (não instalado; cask desativado). SVG bloqueado por segurança. Dos 82 pares públicos de referência, 73 estão implementados; isso não equivale a 82 pares testados nem fidelidade pixel-perfect. PDF→DOCX é textual e não preserva layout/imagens/tabelas. Collage tem teto de 32 MP, arquivos grandes/paginação são limitados; conversões de archive compartilham orçamento com intermediários. Gesto Finder físico, captura TCC ao vivo e sleep/wake precisam de validação interativa.

Testes isolados, sem lançar o hub completo:

```bash
./Tests/FileToolsIntegration/run.sh
./Tests/FileToolsUI/run.sh
./Tests/Feedback/run.sh
./Tests/FeedbackIntegration/run.sh
./Tests/FloatingRadial/run.sh
./Tests/RadialActions/run.sh
./Tests/FileSelection/run.sh
./Tests/SelectionHotKeys/run.sh
./Tests/ContextualWheel/run.sh
./Tests/SelectionPipeline/run.sh
./Tests/Soak/run.sh 4        # ditado real (whisper-cli) N vezes: memória estável e 0 leaks
```

**Cuidado operacional:** `smoke.sh` lança instâncias completas; a reconciliação de insônia pode executar pmset e registrar hooks globais. `install.sh` para o agente existente e substitui o bundle; não executar durante sessões ativas sem aprovação específica.

## Desempenho parado

`./perf.sh` abre o build, espera 20 s, mede 60 s e falha acima da meta (footprint ≤ 25 MB,
≤ 0,5 idle wakeups/s, 0 leaks). Saia do app instalado antes. Em 2026-10-14: 33 MB e ~6,5 wakeups/s
antes; 14 MB e 0,2–0,3 wakeups/s depois de tirar Mac Duo, o arraste legado e os polls de 5 s.

## Migração do Garime Whisper

`./migrate.sh` (uma vez): recusa rodar com o app antigo aberto ou call gravando, faz backup em
`~/Library/Application Support/Garime/Backups/Whisper/<stamp>/`, copia os ajustes de Sons, remove
`ai.garime.whisper` e instala `ai.garime.hub`. Depois conceda de novo Microfone, Acessibilidade e
Automação → Finder — o macOS liga permissões ao bundle id.

## Layout

```
Sources/App/            main, AppDelegate (wiring), Config (every path/constant)
Sources/Audio/          Recorder, LevelMeter, StreamBuffer, FlushGuard
Sources/Transcribe/     Transcriber, WhisperBackend, WindowedDecoder, Stabilizer, TextChunker
Sources/Dictation/      DictationSession, Hotkey, Paster, Typist, FocusAnchor
Sources/Sessions/       MeetingController, MeetingArchive, CallController
Sources/System/         InsomniaController, SleepBlocker, CapsWatcher, ProcessRunner, PathWatcher
Sources/UI/             StatusIcon, IconAnimation, DotMatrix, HubPanel, MenuController
Sources/Integrations/   TasksController, VaultTasks, ScreenshotClipboard
Sources/FileTools/      Backend seguro e UI radial/Finder
Sources/Feedback/       síntese original, playback em memória, política e ajustes persistentes
Tests/<Suite>/main.swift  one harness per suite (Transcriber, Units, Decoder, Icon, Stream, Recorder, Bench)
```

`build.sh` compiles every `.swift` under `Sources/` recursively, so a new group is just a new
folder. `smoke.sh` and `bench.sh` resolve sources **by file name** (`$(src StatusIcon)`), never by
path, and §0 of `smoke.sh` fails if a file sits loose in `Sources/` or if two groups share a name.

## Build

```bash
./build.sh          # -> build/GarimeHub.app
./smoke.sh          # non-interactive gate (93 checks and growing), must end "failed: 0"
```

Built with `swiftc` directly against the Command Line Tools SDK — **Xcode is not required** and
there is no `.xcodeproj` to hand-edit. `build.sh` signs with the first available
`Apple Development` / `Developer ID` identity (team `6RRNRWCXSD`) so TCC grants survive rebuilds;
it falls back to ad-hoc signing with a warning, in which case macOS re-asks for permissions on
every rebuild.

## Install

```bash
./install.sh
```

Copies the app to `~/Applications/Garime Hub.app` (a stable path — TCC keys on it), writes
`~/Library/LaunchAgents/ai.garime.hub.plist`, and bootstraps it. `RunAtLoad` starts it at
login; `KeepAlive` is `false` so **Sair** in the menu really quits. Logs land in
`~/Library/Logs/garime/garimehub.{out,err}`.

## Runtime dependencies

| What | Where |
|---|---|
| whisper.cpp CLI | `/opt/homebrew/bin/whisper-cli` |
| model | `~/.cache/whisper/ggml-large-v3-turbo.bin` |
| ffmpeg | `/opt/homebrew/bin/ffmpeg` |

Missing any of them is not a crash: the menu-bar icon goes to the error state and the menu's first
line names the missing path.

## Hub notes

- **Mutual exclusion**: ⌥Space is refused (a `mic.slash` flash) while a meeting or call records,
  and vice versa. Dictation is available again while a meeting transcribes in the background.
- **A meeting never loses audio**: the capture is moved into its `~/Recordings/` folder before
  conversion; a wedged whisper leaves `audio.wav` in place and only the transcript is missing.
  An audio-device change mid-meeting stops and transcribes instead of aborting.
- **Insomnia does not persist**: a reboot always comes back with sleep enabled.
- **Tasks are read-only and lazy**: launch only loads the local cache; opening the hub/menu refreshes
  stale data. The remote command is exactly `cat` of the tasks glob, `BatchMode=yes`, and the menu
  shows how old the data is ("atualizado há 3 min" / "offline — cache de 2 h").
- **Idle lifecycle is quiet**: the icon has no idle timer, task refresh creates no background timer
  or launch-time SSH process, and safety poll timers use tolerance so macOS can coalesce wakeups.

## Behaviour (dictation)

`idle → recording → transcribing → success/error → idle`. The icon is a monochrome template
symbol per state, animated while recording and transcribing. ⌥Space during *transcribing* cancels;
a generation token guarantees the cancelled result can never paste late.

Clipboard rules:

- The clipboard is snapshotted (every item, every type, in the original type order) before pasting
  and restored ~800 ms later **only if `changeCount` is unchanged** — if you or a clipboard manager
  wrote in the meantime, it is left alone.
- Secure input active, or a focused `AXSecureTextField`, means **no synthetic paste at all**: the
  text is copied — marked `org.nspasteboard.ConcealedType` so clipboard managers skip it — and the
  menu says so.
- Without Accessibility, same fallback — copy and tell you to press ⌘V. The menu grows an
  "Ativar colagem automática…" item that opens the right settings pane.
- Only ⌘V is ever synthesized. **Enter is never sent** (asserted by `smoke.sh`).

Recording auto-stops at 120 s; clips under 0.4 s are discarded. Temp audio is deleted on every
exit path. Transcription is bounded by a 180 s watchdog that runs off the transcriber's own serial
queue, so a wedged `ffmpeg`/`whisper-cli` is killed instead of pinning the app in "Transcrevendo…";
`smoke.sh` §13 compiles `Sources/Transcriber.swift` against stub binaries to prove the watchdog and
the cancel path actually terminate children.

## Verified interactively

`smoke.sh` cannot exercise the microphone or the paste keystroke without a human (both are
TCC-gated). After the first install, confirm once by hand: ⌥Space in TextEdit, speak, ⌥Space.
