# Flow

Personal Wispr Flow replacement. 100% free, 100% on-device, zero subscriptions.

- **Hold fn** — speak, release, and AI-cleaned text is pasted into the focused app.
- **fn + space** — hands-free mode: sentences are typed live as you speak.
  fn+space again to finish, **Esc** to cancel.
- Menu bar: AI cleanup toggle, last-10 history (click to re-paste), launch at login.

## How it stays free

| Stage | Tech |
|---|---|
| Speech-to-text | Apple `SpeechTranscriber` (macOS 26, on-device) |
| AI cleanup | Apple `FoundationModels` on-device LLM, regex fallback |
| Typing | Clipboard + synthesized ⌘V, clipboard restored after |

Nothing ever leaves the Mac.

## Install

One-liner (requires Xcode 26+):

```sh
curl -fsSL https://raw.githubusercontent.com/Littlemowmow/flow/main/Scripts/install.sh | zsh
```

Or manually:

```sh
git clone https://github.com/Littlemowmow/flow.git && cd flow
Scripts/bundle.sh
cp -R build/Flow.app /Applications/
open /Applications/Flow.app
```

Requires macOS 26 on Apple Silicon. Apple Intelligence enabled gets you the
on-device AI cleanup; without it Flow falls back to regex cleanup.

## One-time setup

1. Grant **Accessibility**, **Input Monitoring**, and **Microphone** when prompted
   (or via the ⚠️ menu item).
2. System Settings → Keyboard → "Press 🌐 key to" must be **Do Nothing**
   (`defaults write com.apple.HIToolbox AppleFnUsageType -int 0`).
3. First launch downloads the speech model if missing (progress in the menu).

Note: rebuilding re-signs the binary ad-hoc, so macOS may re-ask for the
permission grants after `cp -R` to /Applications.

## Development

```sh
swift test        # unit tests (cleaner, history)
swift build       # debug build
Scripts/bundle.sh # release Flow.app
```

Design and plan in `docs/plans/`.
