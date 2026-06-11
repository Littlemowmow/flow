import AppKit
import Carbon.HIToolbox
import os

/// Pastes text into the focused app: save clipboard, set text, synthesize ⌘V,
/// restore clipboard. No-ops (with a beep) when a secure input field is focused.
///
/// Two ⌘V mechanisms, selectable via `defaults write com.hadi.flow pasteMechanism -int N`:
/// 1 (default): V keydown/keyup with the command flag, posted to the HID tap.
/// 2: explicit Cmd-down, V-down, V-up, Cmd-up envelope with small delays,
///    posted to the session tap — for apps that track physical modifier state.
public enum Paster {
    static let log = Logger(subsystem: "com.hadi.flow", category: "paster")

    public static var mechanism: Int {
        get { max(1, min(2, UserDefaults.standard.integer(forKey: "pasteMechanism").nonZeroOr(1))) }
        set { UserDefaults.standard.set(newValue, forKey: "pasteMechanism") }
    }

    public static func paste(_ text: String) {
        guard !text.isEmpty else {
            log.info("paste skipped: empty text")
            return
        }
        guard !IsSecureEventInputEnabled() else {
            log.error("paste blocked: secure input field is active")
            NSSound.beep()
            return
        }
        let trusted = AXIsProcessTrusted()
        log.info("paste: \(text.count) chars, mechanism \(mechanism), axTrusted \(trusted)")
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        sendCmdV()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Only restore if nothing else has touched the clipboard since.
            if let saved, pb.string(forType: .string) == text {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    /// Synthesize ⌘C and return the selection found on the clipboard, restoring
    /// the previous clipboard. Returns nil if nothing was copied.
    public static func copySelection() -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else { return nil }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let before = pb.changeCount
        sendKey(CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
        // Wait up to 0.6s for the app to service the copy.
        for _ in 0..<12 where pb.changeCount == before {
            usleep(50_000)
        }
        defer {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
        guard pb.changeCount != before else {
            log.info("copySelection: clipboard unchanged (no selection?)")
            return nil
        }
        return pb.string(forType: .string)
    }

    private static func sendCmdV() {
        if mechanism == 2 {
            let src = CGEventSource(stateID: .hidSystemState)
            let cmd = CGKeyCode(kVK_Command)
            let v = CGKeyCode(kVK_ANSI_V)
            let events: [(CGKeyCode, Bool, CGEventFlags)] = [
                (cmd, true, .maskCommand),
                (v, true, .maskCommand),
                (v, false, .maskCommand),
                (cmd, false, []),
            ]
            for (key, down, flags) in events {
                let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cgSessionEventTap)
                usleep(10_000)
            }
        } else {
            sendKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        }
        log.info("sendCmdV posted (mechanism \(mechanism))")
    }

    private static func sendKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
