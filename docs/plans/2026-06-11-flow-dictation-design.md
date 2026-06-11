# Flow — Personal Dictation for macOS

**Date:** 2026-06-11
**Status:** Approved

A personal Wispr Flow replacement: hold a hotkey, speak, and cleaned-up text
appears in whatever app is focused. 100% free, 100% on-device.

## Goals

- Hold **fn** to dictate; release to transcribe, clean, and paste.
- **fn+space** toggles hands-free mode: continuous dictation, finalized
  sentences typed live until toggled off (or Esc).
- AI cleanup that costs nothing: Apple's on-device Foundation Models LLM.
- Works in any app via clipboard paste with save/restore.

## Environment (verified)

- Apple Silicon, macOS 26.3, Xcode 26.3, Swift 6.2.4.
- Apple Intelligence enabled (Foundation Models available).
- `SpeechTranscriber` / `SpeechAnalyzer` (macOS 26 speech API) available.

## Architecture

Single SwiftPM executable bundled as a menu bar app (`LSUIElement`, no Dock
icon). Five components:

### HotkeyMonitor
- `CGEventTap` on `flagsChanged` + `keyDown`.
- fn down → start recording; fn up → stop, transcribe, paste.
- fn+space → toggle hands-free; Esc exits hands-free.
- Needs Accessibility + Input Monitoring permissions (one-time grant).
- Setup note: Settings → Keyboard → "Press 🌐 key to" must be **Do Nothing**
  so the emoji picker / native dictation don't conflict.

### Recorder
- `AVAudioEngine` input tap, buffers streamed straight to the transcriber.
  No temp files.

### Transcriber
- `SpeechTranscriber` (on-device), pre-warmed at launch.
- Hold mode: use the final transcript on release.
- Hands-free: consume finalized segments as they arrive, type each one.
- Model assets downloaded via `AssetInventory` if missing (progress in menu).

### Cleaner
- `FoundationModels` `LanguageModelSession`, tight system prompt: remove
  filler words (um, uh, like, you know), fix punctuation/capitalization,
  apply spoken commands ("new line", "comma"), never add or rephrase content.
- Skipped for utterances under 4 words (latency not worth it).
- Fallback to regex cleanup if model unavailable or >2s timeout.
- Toggleable from the menu.

### Paster
- Save clipboard → set transcript → synthesize ⌘V via `CGEvent` → restore
  clipboard after 300ms.
- Secure input fields: detect and no-op rather than paste garbage.

## Feedback / UI

- Menu bar icon swaps to a recording glyph while listening.
- Floating HUD pill near screen bottom shows live volatile transcript.
- Subtle start/stop sounds.
- Menu: hands-free toggle, AI cleanup on/off, last-10 transcript history,
  launch-at-login, quit.

## Error handling

- Missing permissions → menu explains which grant, deep-links to the right
  Settings pane.
- Speech model not downloaded → trigger download, show progress.
- Empty/failed transcription → soft error sound, type nothing.
- Cleanup failure → paste raw transcript (never lose words).

## Build & install

- SwiftPM at `~/Developer/flow`; `swift build` + a bundling script produces
  `Flow.app` (ad-hoc signed, copied to /Applications optional).

## Testing

- Unit tests: regex cleaner, clipboard save/restore logic.
- Live verification: build, launch, user dictates into a real app.

## Alternatives rejected

- Hammerspoon/Python: extra runtimes, laggier hold-key UX.
- whisper.cpp + cloud/Ollama LLM: 1.6GB download, more latency, no quality
  win over Apple's stack on this hardware.
