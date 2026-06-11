import AppKit

/// Global hotkey watcher via CGEventTap.
/// - Hold fn (keycode 63): onFnDown / onFnUp.
/// - fn+space: onHandsFreeToggle (the space event is swallowed).
/// - Esc while hands-free: onEscape (swallowed).
/// Requires Accessibility + Input Monitoring permissions.
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
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
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
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
