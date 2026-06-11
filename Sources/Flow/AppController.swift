import AppKit
import AVFoundation
import ServiceManagement
import os
import FlowCore

/// Menu bar app + dictation state machine.
///
/// Hold fn       -> record -> release -> transcribe -> AI clean -> paste.
/// fn+space      -> hands-free: finalized sentences are typed live until
///                  fn+space again (finish) or Esc (cancel).
/// Hold right-⌥  -> speak an instruction; on release Flow copies the current
///                  selection, applies the instruction to it (or generates
///                  text from scratch), and pastes the result.
final class AppController: NSObject {
    private static let log = Logger(subsystem: "com.hadi.flow", category: "app")

    private enum State {
        case idle
        case recording(handsFree: Bool)
        case rewriteRecording
        case processing
    }

    private var state: State = .idle
    private var statusItem: NSStatusItem!
    private let hud = HUD()
    private let monitor = HotkeyMonitor()
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner()
    private let history = TranscriptHistory(limit: 10)

    /// Hands-free: finalized text accumulated before hands-free was toggled
    /// (typed at toggle time) and the full session text for history.
    private var unpastedHoldText = ""
    private var handsFreeSessionText = ""
    /// True while a hands-free session is flushing its final audio, so tail
    /// segments arriving during .processing still get typed.
    private var handsFreeFlushing = false
    /// App the user was dictating into, captured when recording starts.
    private var targetAppName: String?

    private var selfTestWindow: NSWindow?
    private var selfTestTextView: NSTextView?

    private var permissionTimer: Timer?
    private var tapRunning = false
    private var modelReady = false
    private var modelError: String?

    func start() {
        UserDefaults.standard.register(defaults: ["aiCleanup": true])
        cleaner.enabled = UserDefaults.standard.bool(forKey: "aiCleanup")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("mic")
        rebuildMenu()

        wireMonitor()
        wireTranscriber()
        requestPermissions()
        downloadModelIfNeeded()
    }

    // MARK: - Wiring

    private func wireMonitor() {
        monitor.isHandsFreeActive = { [weak self] in
            if case .recording(handsFree: true) = self?.state { return true }
            return false
        }
        monitor.onFnDown = { [weak self] in self?.fnDown() }
        monitor.onFnUp = { [weak self] consumed in self?.fnUp(consumed: consumed) }
        monitor.onRewriteDown = { [weak self] in self?.rewriteDown() }
        monitor.onRewriteUp = { [weak self] in self?.rewriteUp() }
        monitor.onHandsFreeToggle = { [weak self] in self?.handsFreeToggle() }
        monitor.onEscape = { [weak self] in self?.cancelHandsFree() }
    }

    private func wireTranscriber() {
        transcriber.onVolatile = { [weak self] text in
            DispatchQueue.main.async { self?.hud.show(text) }
        }
        transcriber.onFinalSegment = { [weak self] segment in
            DispatchQueue.main.async { self?.finalSegmentArrived(segment) }
        }
        recorder.onBuffer = { [weak self] buffer in
            self?.transcriber.feed(buffer)
        }
    }

    // MARK: - State machine

    private func fnDown() {
        guard case .idle = state else { return }
        guard tapRunning, modelReady else { NSSound(named: "Basso")?.play(); return }
        Self.log.info("fnDown: starting hold recording")
        state = .recording(handsFree: false)
        beginRecordingSession(icon: ("mic.fill", .systemRed))
    }

    private func rewriteDown() {
        guard case .idle = state else { return }
        guard tapRunning, modelReady else { NSSound(named: "Basso")?.play(); return }
        Self.log.info("rewriteDown: starting rewrite recording")
        state = .rewriteRecording
        beginRecordingSession(icon: ("wand.and.stars", .systemPurple))
    }

    private func beginRecordingSession(icon: (String, NSColor)) {
        unpastedHoldText = ""
        handsFreeSessionText = ""
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        setIcon(icon.0, tint: icon.1)
        hud.show("")
        NSSound(named: "Pop")?.play()
        Task { @MainActor in
            do {
                try await transcriber.start()
                try recorder.start()
            } catch {
                self.failSession("Couldn't start audio: \(error.localizedDescription)")
            }
        }
    }

    private func fnUp(consumed: Bool) {
        guard !consumed else { return }            // fn+space already handled this hold
        guard case .recording(handsFree: false) = state else { return }
        state = .processing
        setIcon("waveform")
        recorder.stop()
        Task { @MainActor in
            let raw = await transcriber.stop()
            Self.log.info("fnUp: raw transcript \(raw.count) chars")
            let cleaned = await cleaner.clean(raw, appName: self.targetAppName)
            Self.log.info("fnUp: cleaned \(cleaned.count) chars -> pasting")
            self.finishHold(with: cleaned)
        }
    }

    private func rewriteUp() {
        guard case .rewriteRecording = state else { return }
        state = .processing
        setIcon("waveform")
        recorder.stop()
        Task { @MainActor in
            let instruction = await transcriber.stop()
            Self.log.info("rewriteUp: instruction \(instruction.count) chars")
            guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.finishHold(with: "")
                return
            }
            self.hud.show("✍️ thinking…")
            // Option key is released now, so ⌘C is safe to synthesize.
            let selection = Paster.copySelection()
            Self.log.info("rewriteUp: selection \(selection?.count ?? 0) chars")
            let result = await self.cleaner.transform(instruction: instruction, selection: selection)
            self.finishHold(with: result ?? "")
        }
    }

    private func finishHold(with text: String) {
        hud.hide()
        if text.isEmpty {
            Self.log.info("finish: empty result, nothing pasted")
            NSSound(named: "Basso")?.play()
        } else {
            Paster.paste(text)
            history.add(text)
            NSSound(named: "Tink")?.play()
        }
        state = .idle
        setIcon("mic")
        rebuildMenu()
    }

    private func handsFreeToggle() {
        switch state {
        case .recording(handsFree: false):
            // Convert the in-progress hold into hands-free. Type anything
            // already finalized, then stream from here on.
            state = .recording(handsFree: true)
            setIcon("mic.fill", tint: .systemOrange)
            if !unpastedHoldText.isEmpty {
                pasteSegment(unpastedHoldText)
                unpastedHoldText = ""
            }
        case .recording(handsFree: true):
            endHandsFree()
        default:
            break
        }
    }

    private func endHandsFree() {
        state = .processing
        handsFreeFlushing = true
        setIcon("waveform")
        recorder.stop()
        Task { @MainActor in
            // Remaining audio finalizes during stop(); those tail segments
            // are pasted by finalSegmentArrived via handsFreeFlushing.
            _ = await transcriber.stop()
            self.handsFreeFlushing = false
            self.hud.hide()
            self.history.add(self.handsFreeSessionText)
            NSSound(named: "Tink")?.play()
            self.state = .idle
            self.setIcon("mic")
            self.rebuildMenu()
        }
    }

    private func cancelHandsFree() {
        guard case .recording(handsFree: true) = state else { return }
        state = .processing
        recorder.stop()
        Task { @MainActor in
            await transcriber.cancel()
            self.hud.hide()
            NSSound(named: "Basso")?.play()
            self.state = .idle
            self.setIcon("mic")
        }
    }

    private func finalSegmentArrived(_ segment: String) {
        switch state {
        case .recording(handsFree: false):
            unpastedHoldText += segment
        case .recording(handsFree: true):
            pasteSegment(segment)
        case .processing:
            if handsFreeFlushing {
                pasteSegment(segment)
            }
        case .rewriteRecording, .idle:
            break
        }
    }

    private func pasteSegment(_ segment: String) {
        let cleaned = RegexCleaner.clean(segment)
        guard !cleaned.isEmpty else { return }
        Paster.paste(cleaned + " ")
        handsFreeSessionText += (handsFreeSessionText.isEmpty ? "" : " ") + cleaned
    }

    private func failSession(_ message: String) {
        recorder.stop()
        Task { await transcriber.cancel() }
        hud.hide()
        NSSound(named: "Basso")?.play()
        state = .idle
        setIcon("mic")
        NSLog("Flow: %@", message)
    }

    // MARK: - Permissions & model

    private func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        tryStartTap()
        if !tapRunning {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.tryStartTap()
            }
        }
    }

    private func tryStartTap() {
        guard !tapRunning else { return }
        tapRunning = monitor.start()
        if tapRunning {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
        rebuildMenu()
    }

    private func downloadModelIfNeeded() {
        Task { @MainActor in
            do {
                try await Transcriber.ensureModel()
                self.modelReady = true
            } catch {
                self.modelError = error.localizedDescription
            }
            self.rebuildMenu()
        }
    }

    // MARK: - UI

    private func setIcon(_ symbol: String, tint: NSColor? = nil) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Flow")
        if let tint {
            statusItem.button?.contentTintColor = tint
        } else {
            statusItem.button?.contentTintColor = nil
        }
        statusItem.button?.image = image
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        if !tapRunning {
            let warn = NSMenuItem(title: "⚠️ Grant Accessibility & Input Monitoring…",
                                  action: #selector(openPrivacySettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        if !modelReady {
            let title = modelError.map { "⚠️ Speech model: \($0)" } ?? "Downloading speech model…"
            menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Hold fn to dictate · fn+space hands-free",
                                action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Hold right-⌥, speak to rewrite selection / write",
                                action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let selfTest = NSMenuItem(title: "Run Paste Self-Test",
                                  action: #selector(runPasteSelfTest), keyEquivalent: "")
        selfTest.target = self
        menu.addItem(selfTest)

        let ai = NSMenuItem(title: "AI Cleanup", action: #selector(toggleAI), keyEquivalent: "")
        ai.target = self
        ai.state = cleaner.enabled ? .on : .off
        menu.addItem(ai)

        if !history.entries.isEmpty {
            let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for entry in history.entries {
                let title = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
                let item = NSMenuItem(title: title, action: #selector(repaste(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry
                sub.addItem(item)
            }
            historyItem.submenu = sub
            menu.addItem(historyItem)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Quit Flow", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleAI() {
        cleaner.enabled.toggle()
        UserDefaults.standard.set(cleaner.enabled, forKey: "aiCleanup")
        rebuildMenu()
    }

    @objc private func repaste(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // Give the user a beat to refocus the target app after the menu closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Paster.paste(text)
        }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Flow: launch-at-login failed: %@", error.localizedDescription)
        }
        rebuildMenu()
    }

    // MARK: - Paste self-test

    /// Pastes a marker into Flow's own window to verify the synthesized ⌘V
    /// mechanism end-to-end. If mechanism 1 fails, automatically tries and
    /// adopts mechanism 2.
    @objc private func runPasteSelfTest() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Flow Paste Self-Test"
        win.contentView = tv
        win.isReleasedWhenClosed = false
        selfTestWindow = win
        selfTestTextView = tv
        NSApp.activate(ignoringOtherApps: true)
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(tv)
        attemptSelfTest(mechanism: Paster.mechanism, isRetry: false)
    }

    private func attemptSelfTest(mechanism: Int, isRetry: Bool) {
        Paster.mechanism = mechanism
        let marker = "FLOW-PASTE-TEST-M\(mechanism)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Paster.paste(marker)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let ok = self.selfTestTextView?.string.contains(marker) ?? false
                Self.log.info("selfTest mechanism \(mechanism): \(ok ? "PASS" : "FAIL")")
                if ok {
                    self.finishSelfTest(message: "Paste works (mechanism \(mechanism))\(isRetry ? " — switched to it permanently." : ".")")
                } else if !isRetry, mechanism == 1 {
                    self.attemptSelfTest(mechanism: 2, isRetry: true)
                } else {
                    Paster.mechanism = 1
                    self.finishSelfTest(message: """
                    Paste FAILED with both mechanisms. This is almost always the \
                    Accessibility permission: System Settings → Privacy & Security → \
                    Accessibility → turn Flow OFF and back ON, then quit and reopen Flow.
                    """)
                }
            }
        }
    }

    private func finishSelfTest(message: String) {
        selfTestWindow?.close()
        selfTestWindow = nil
        selfTestTextView = nil
        let alert = NSAlert()
        alert.messageText = "Paste Self-Test"
        alert.informativeText = message
        alert.runModal()
    }

    @objc private func openPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ]
        for u in urls {
            if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        }
    }
}
