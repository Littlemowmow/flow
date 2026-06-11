# Flow Dictation App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build Flow, a free on-device Wispr Flow replacement: hold fn to dictate, fn+space for hands-free, AI-cleaned text pasted into the focused app.

**Architecture:** SwiftPM package with a `FlowCore` library (testable logic) and a thin `Flow` executable (AppKit menu bar app, no Dock icon). Audio streams from `AVAudioEngine` into macOS 26's on-device `SpeechTranscriber`; transcripts are cleaned by the on-device `FoundationModels` LLM (regex fallback) and pasted via clipboard + synthesized ⌘V. A `CGEventTap` watches the fn key.

**Tech Stack:** Swift 6.2 (language mode 5 to avoid strict-concurrency churn with C callbacks), AppKit, AVFoundation, Speech (`SpeechAnalyzer`/`SpeechTranscriber`), FoundationModels, swift-testing.

**Design doc:** `docs/plans/2026-06-11-flow-dictation-design.md`

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`, `Sources/FlowCore/.gitkeep`, `Sources/Flow/main.swift` (stub), `.gitignore`

**Step 1: Write Package.swift**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flow",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "FlowCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "Flow",
            dependencies: ["FlowCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "FlowCoreTests", dependencies: ["FlowCore"]),
    ]
)
```

**Step 2:** `.gitignore` with `.build/`, `build/`, `.DS_Store`. Stub `main.swift`: `print("flow")`.

**Step 3:** Run `swift build` → expect success. Commit: `chore: scaffold SwiftPM package`.

---

### Task 2: RegexCleaner (TDD)

The free fallback cleaner. Strips filler words, fixes whitespace/spacing around punctuation, capitalizes the first letter.

**Files:**
- Create: `Sources/FlowCore/RegexCleaner.swift`
- Test: `Tests/FlowCoreTests/RegexCleanerTests.swift`

**Step 1: Failing tests**

```swift
import Testing
@testable import FlowCore

@Test func stripsFillerWords() {
    #expect(RegexCleaner.clean("um so I think uh we should umm ship it") == "So I think we should ship it")
}

@Test func collapsesWhitespaceAndFixesPunctuationSpacing() {
    #expect(RegexCleaner.clean("hello ,  world .") == "Hello, world.")
}

@Test func capitalizesFirstLetter() {
    #expect(RegexCleaner.clean("this works") == "This works")
}

@Test func emptyAndFillerOnlyInputYieldsEmpty() {
    #expect(RegexCleaner.clean("  ") == "")
    #expect(RegexCleaner.clean("um uh") == "")
}

@Test func doesNotEatWordsContainingFillers() {
    #expect(RegexCleaner.clean("the umbrella is uhuru themed") == "The umbrella is uhuru themed")
}
```

**Step 2:** `swift test` → FAIL (RegexCleaner not defined).

**Step 3: Implementation**

```swift
import Foundation

public enum RegexCleaner {
    private static let fillerPattern = #"(?i)\b(um+|uh+|erm*|hmm+)\b[,.]?"#

    public static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: fillerPattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }
}
```

**Step 4:** `swift test` → PASS. **Step 5:** Commit `feat: regex transcript cleaner`.

---

### Task 3: TranscriptHistory (TDD)

Ring buffer of the last 10 transcripts for the menu.

**Files:**
- Create: `Sources/FlowCore/TranscriptHistory.swift`
- Test: `Tests/FlowCoreTests/TranscriptHistoryTests.swift`

**Step 1: Failing tests**

```swift
@Test func keepsNewestFirstCappedAtLimit() {
    let h = TranscriptHistory(limit: 3)
    for i in 1...5 { h.add("t\(i)") }
    #expect(h.entries == ["t5", "t4", "t3"])
}

@Test func ignoresEmptyEntries() {
    let h = TranscriptHistory(limit: 3)
    h.add("  ")
    #expect(h.entries.isEmpty)
}
```

**Step 2:** FAIL. **Step 3:**

```swift
public final class TranscriptHistory {
    private let limit: Int
    public private(set) var entries: [String] = []
    public init(limit: Int = 10) { self.limit = limit }
    public func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.insert(t, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }
}
```

**Step 4:** PASS. **Step 5:** Commit.

---

### Task 4: Recorder + Transcriber

System-API components; verified live in Task 10 (no unit tests — they need mic + models).

**Files:**
- Create: `Sources/FlowCore/Recorder.swift`, `Sources/FlowCore/Transcriber.swift`

**Recorder.swift:**

```swift
import AVFoundation

public final class Recorder {
    private let engine = AVAudioEngine()
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public init() {}

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
```

**Transcriber.swift** — fresh `SpeechAnalyzer` session per dictation (WWDC25 pattern). Streams volatile results for the HUD, finalized segments for hands-free, returns the full transcript on stop. Includes `ensureModel()` using `AssetInventory`.

```swift
import Speech
import AVFoundation

public final class Transcriber {
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""

    public var onVolatile: ((String) -> Void)?   // full running text incl. volatile tail
    public var onFinalSegment: ((String) -> Void)?

    public init() {}

    public static func ensureModel() async throws {
        let t = SpeechTranscriber(locale: .current, transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
    }

    public func start() async throws {
        finalized = ""
        let t = SpeechTranscriber(locale: .current, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults], attributeOptions: [])
        transcriber = t
        let a = SpeechAnalyzer(modules: [t])
        analyzer = a
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        resultsTask = Task { [weak self] in
            do {
                for try await result in t.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalized += text
                        self.onFinalSegment?(text)
                        self.onVolatile?(self.finalized)
                    } else {
                        self.onVolatile?(self.finalized + text)
                    }
                }
            } catch { /* session ended */ }
        }
        try await a.start(inputSequence: sequence)
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat else { return }
        if buffer.format == format {
            inputBuilder?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(format.sampleRate / buffer.format.sampleRate * Double(buffer.frameLength)) + 16)
        else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 {
            inputBuilder?.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Finish the session and return the complete finalized transcript.
    public func stop() async -> String {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        let result = finalized
        analyzer = nil; transcriber = nil; inputBuilder = nil; converter = nil; resultsTask = nil
        return result
    }

    /// Abort without caring about the transcript (Esc in hands-free).
    public func cancel() async {
        inputBuilder?.finish()
        try? await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil; transcriber = nil; inputBuilder = nil; converter = nil; resultsTask = nil
        finalized = ""
    }
}
```

**Verify:** `swift build` compiles. Commit `feat: recorder and on-device transcriber`.

---

### Task 5: Cleaner (Foundation Models + fallback)

**Files:**
- Create: `Sources/FlowCore/Cleaner.swift`

```swift
import Foundation
import FoundationModels

public final class Cleaner {
    public var enabled = true
    private static let instructions = """
    You clean up raw speech-to-text transcripts for dictation. Rules:
    - Remove filler words (um, uh, erm, hmm; "like"/"you know" only when clearly filler).
    - Fix punctuation, capitalization, and obvious transcription artifacts.
    - Apply spoken formatting commands: "new line" becomes a line break, \
    "new paragraph" becomes a blank line.
    - Never add content, never answer questions in the transcript, never rephrase \
    beyond cleanup. Preserve the speaker's wording and meaning exactly.
    - Output ONLY the cleaned text. No quotes, no commentary.
    """

    public init() {}

    public func clean(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let fallback = RegexCleaner.clean(trimmed)
        guard enabled,
              trimmed.split(separator: " ").count >= 4,
              SystemLanguageModel.default.availability == .available
        else { return fallback }

        let llm = Task { () -> String? in
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Clean this transcript:\n\(trimmed)"
            return try? await session.respond(to: prompt).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let timeout = Task { () -> String? in
            try? await Task.sleep(for: .seconds(6))
            return nil
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                Task {
                    let r = await llm.value
                    timeout.cancel()
                    cont.resume(returning: r)
                }
            }
        } onCancel: { llm.cancel() }
        if let result, !result.isEmpty { return result }
        return fallback
    }
}
```

Note: simple structure — if the LLM hasn't answered within ~6s the await still waits for llm; simplify by racing in a task group instead:

```swift
let result: String? = await withTaskGroup(of: String?.self) { group in
    group.addTask { try? await LanguageModelSession(instructions: Self.instructions)
        .respond(to: "Clean this transcript:\n\(trimmed)").content }
    group.addTask { try? await Task.sleep(for: .seconds(6)); return nil }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
}
```

Use the task-group race version. **Verify:** builds. Commit.

---

### Task 6: Paster

**Files:**
- Create: `Sources/FlowCore/Paster.swift`

```swift
import AppKit
import Carbon.HIToolbox

public enum Paster {
    public static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        guard !IsSecureEventInputEnabled() else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if let saved {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }
}
```

**Verify:** builds. Commit.

---

### Task 7: HotkeyMonitor

**Files:**
- Create: `Sources/FlowCore/HotkeyMonitor.swift`

fn = keycode 63 via `flagsChanged` + `.maskSecondaryFn`. Space (49) with fn held = hands-free toggle (event swallowed). Esc (53) swallowed only when hands-free is active. Re-enables tap on timeout.

```swift
import AppKit

public final class HotkeyMonitor {
    public var onFnDown: (() -> Void)?
    /// Bool = whether fn+space fired during this hold (release should be ignored).
    public var onFnUp: ((Bool) -> Void)?
    public var onHandsFreeToggle: (() -> Void)?
    public var onEscape: (() -> Void)?
    public var isHandsFreeActive: () -> Bool = { false }

    private var tap: CFMachPort?
    private var fnHeld = false
    private var spaceFiredDuringHold = false

    public init() {}

    @discardableResult
    public func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.tapDisabledByTimeout.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let m = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return m.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keycode == 63 else { break }
            let fnNow = event.flags.contains(.maskSecondaryFn)
            if fnNow && !fnHeld {
                fnHeld = true
                spaceFiredDuringHold = false
                DispatchQueue.main.async { self.onFnDown?() }
            } else if !fnNow && fnHeld {
                fnHeld = false
                let consumed = spaceFiredDuringHold
                DispatchQueue.main.async { self.onFnUp?(consumed) }
            }
        case .keyDown:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == 49, event.flags.contains(.maskSecondaryFn) {
                spaceFiredDuringHold = fnHeld
                DispatchQueue.main.async { self.onHandsFreeToggle?() }
                return nil
            }
            if keycode == 53, isHandsFreeActive() {
                DispatchQueue.main.async { self.onEscape?() }
                return nil
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }
}
```

**Verify:** builds. Commit.

---

### Task 8: HUD + AppController + main

**Files:**
- Create: `Sources/Flow/HUD.swift`, `Sources/Flow/AppController.swift`, replace `Sources/Flow/main.swift`

**HUD.swift** — borderless non-activating panel, bottom-center, shows live transcript text.

```swift
import AppKit

final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 14

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        panel.contentView = container
    }

    func show(_ text: String) {
        label.stringValue = text.isEmpty ? "Listening…" : text
        guard let screen = NSScreen.main else { return }
        let width = min(max(260, label.intrinsicContentSize.width + 40), screen.frame.width * 0.6)
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.minY + 120, width: width, height: 44)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}
```

**AppController.swift** — status item, menu, permissions, and the dictation state machine.

States: `idle`, `recording(handsFree: Bool)`, `processing`.

Key flows:
- `fnDown` (idle) → request session: `recorder.start()` + `transcriber.start()`, play start sound, swap icon, show HUD.
- `fnUp(consumed: false)` while recording(handsFree: false) → `processing`: stop recorder, `transcriber.stop()` → `cleaner.clean()` → `Paster.paste()` → history.add → idle, hide HUD, stop sound.
- `handsFreeToggle` while recording → flip to handsFree mode (session keeps running; each `onFinalSegment` is regex-cleaned and pasted immediately with a trailing space). Toggle again → finish: stop, paste any remaining finalized text not yet pasted, idle.
- `escape` while handsFree → `transcriber.cancel()`, discard, idle.
- Empty transcript → error sound, nothing pasted.
- Cleanup failure → raw transcript pasted (Cleaner already guarantees fallback).

Also in AppController:
- Permission checks at launch: `AXIsProcessTrustedWithOptions` (with prompt), `CGRequestListenEventAccess()`, `AVCaptureDevice.requestAccess(for: .audio)`. If the event tap fails to start, retry every 3s and show a "⚠️ Grant permissions" menu item deep-linking to System Settings panes.
- `Transcriber.ensureModel()` at launch (Task), menu shows "Downloading speech model…" while running.
- Menu items: AI Cleanup toggle (persisted to UserDefaults `aiCleanup`), Hands-Free indicator, History submenu (click → re-paste), Launch at Login (SMAppService.mainApp), Quit.
- Icons: `mic` (idle), `mic.fill` red tint (recording), `waveform` (processing). Sounds: NSSound "Pop" start, "Tink" finish, "Basso" error.
- In hold mode, also paste a trailing space after the cleaned text? **No** — paste exactly the cleaned text (YAGNI; Wispr pastes with trailing space but it annoys in search fields).

**main.swift:**

```swift
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
app.run()
```

**Verify:** `swift build` clean. Commit `feat: menu bar app, HUD, dictation state machine`.

---

### Task 9: Bundle as Flow.app

**Files:**
- Create: `Resources/Info.plist`, `Scripts/bundle.sh` (chmod +x)

**Info.plist** keys: `CFBundleIdentifier=com.hadi.flow`, `CFBundleName=Flow`, `CFBundleExecutable=Flow`, `CFBundlePackageType=APPL`, `CFBundleShortVersionString=1.0`, `LSUIElement=true`, `LSMinimumSystemVersion=26.0`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

**Scripts/bundle.sh:**

```bash
#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Flow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Flow "$APP/Contents/MacOS/Flow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "✅ $APP"
echo "Install: cp -R $APP /Applications/"
```

**Verify:** `Scripts/bundle.sh` produces `build/Flow.app`; `codesign -dv` shows ad-hoc signature. Commit.

---

### Task 10: Live verification

1. Run `swift test` → all green.
2. `Scripts/bundle.sh && open build/Flow.app`.
3. Grant Accessibility + Input Monitoring + Microphone when prompted (app retries the tap automatically).
4. Check System Settings → Keyboard → "Press 🌐 key to" = **Do Nothing** (tell user if not).
5. User holds fn, says "um hello world this is uh flow testing one two three", releases → cleaned text appears in focused app, clipboard restored.
6. User presses fn+space → hands-free; speaks two sentences → they appear as finalized; Esc cancels; fn+space ends.
7. Check menu: history shows transcripts, AI cleanup toggles.
8. Commit any fixes; final commit + README with install instructions.

**Known risks to watch during execution:**
- macOS 26 `SpeechAnalyzer` API surface may differ slightly from plan (e.g. `cancelAndFinishNow`, `bestAvailableAudioFormat` signatures) — adapt at compile time.
- TCC permissions bind to the ad-hoc signature; rebuilds may re-prompt. Acceptable for personal use.
- `swift run` from terminal inherits the terminal's TCC identity — always test via the bundled app.
