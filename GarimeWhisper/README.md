# GarimeWhisper

The Garime **menu-bar hub** for the Mac: one mic icon, one menu, no Dock, no windows. It grew out
of the dictation app and now concentrates everything the menu bar needs to say:

| Section | What | How |
|---|---|---|
| Ditado | **⌥Space**, speak, **⌥Space** — transcribed locally, typed/pasted into the focused input | native (`whisper-cli` streaming + batch) |
| Reunião | start/stop from the menu → `~/Recordings/<stamp>-reuniao/` with `audio.wav` + `transcript.txt` | native `Recorder` + `whisper-cli` |
| Call | start/stop the `/record` skill's `rec.sh` (BlackHole mix); recordings started from the terminal show up too, mirrored from `~/.cache/whisper/rec.state` | subprocess, `env` with a homebrew PATH |
| Manter acordado | keep the Mac awake lid-closed (capsomnia replacement) | native `IOPMAssertion`, no `caffeinate` |
| Prints | observes GarimeCapture's status files, **read-only**: icon flash per processed print, alert badge + menu line when stranded or heartbeat is stale | 5 s stat poll |
| Tarefas | open Vault tasks, read-only, refreshed over `ssh garime`, offline cache with an age stamp | `ssh` BatchMode + cache in `~/Library/Application Support/Garime/Hub/` |
| Projetos | unchecked `- [ ]` items from every canonical `STATUS.md` under `~/Garime ~/Omni ~/ARCA ~/Lab ~/.claude` (root + 1 level) | local parse on menu open |

The icon carries state: mic (idle), level bars (dictating), `record.circle` (meeting/call),
spinner (transcribing), a moon overlay while insomnia is on, an alert badge while GarimeCapture
needs a human, and a short camera flash when a print is processed.

Dictation, meetings and OCR never leave the Mac. The only network touch is the read-only `ssh`
fetch of Vault tasks over the tailnet.

## Build

```bash
./build.sh          # -> build/GarimeWhisper.app
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

Copies the app to `~/Applications/Garime Whisper.app` (a stable path — TCC keys on it), writes
`~/Library/LaunchAgents/ai.garime.whisper.plist`, and bootstraps it. `RunAtLoad` starts it at
login; `KeepAlive` is `false` so **Sair** in the menu really quits. Logs land in
`~/Library/Logs/garime/garimewhisper.{out,err}`.

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
- **GarimeCapture is observed, never touched**: the watcher only ever `stat`s and reads
  `status/` and `registry/processed.json`; `smoke.sh` fails if a write call appears in it.
  The menu line only exists while something is wrong.
- **Insomnia does not persist**: a reboot always comes back with sleep enabled.
- **Tasks are read-only**: the remote command is exactly `cat` of the tasks glob, `BatchMode=yes`,
  and the menu shows how old the data is ("atualizado há 3 min" / "offline — cache de 2 h").

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
