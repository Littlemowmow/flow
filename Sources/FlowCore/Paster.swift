import AppKit
import Carbon.HIToolbox

/// Pastes text into the focused app: save clipboard, set text, synthesize ⌘V,
/// restore clipboard. No-ops (with a beep) when a secure input field is focused.
public enum Paster {
    public static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        guard !IsSecureEventInputEnabled() else {
            NSSound.beep()
            return
        }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src,
                            virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
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
