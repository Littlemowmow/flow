import AppKit
import AVFoundation
import ServiceManagement
import FlowCore

/// Menu bar app + dictation state machine.
///
/// Hold fn  -> record -> release -> transcribe -> AI clean -> paste.
/// fn+space -> hands-free: finalized sentences are typed live until
///             fn+space again (finish) or Esc (cancel).
final class AppController: NSObject {
    private enum State {
        case idle
        case recording(handsFree: Bool)
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
        state = .recording(handsFree: false)
        unpastedHoldText = ""
        handsFreeSessionText = ""
        setIcon("mic.fill", tint: .systemRed)
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
            let cleaned = await cleaner.clean(raw)
            self.finishHold(with: cleaned)
        }
    }

    private func finishHold(with text: String) {
        hud.hide()
        if text.isEmpty {
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
        case .idle:
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
        menu.addItem(.separator())

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
