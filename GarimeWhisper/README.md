# GarimeWhisper

Menu-bar dictation for macOS. Press **⌥Space**, speak, press **⌥Space** again — the text is
transcribed locally by `whisper-cli` and pasted into whatever input had focus.

Nothing leaves the Mac. No settings UI, no network.

## Build

```bash
./build.sh          # -> build/GarimeWhisper.app
./smoke.sh          # 32 non-interactive checks, must end "failed: 0"
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

## Behaviour

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
