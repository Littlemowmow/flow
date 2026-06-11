import AppKit

/// Floating Wispr-style pill near the bottom of the screen showing the
/// live transcript while dictating. Non-activating: never steals focus.
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
        panel.hidesOnDeactivate = false
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
        let width = min(max(260, label.intrinsicContentSize.width + 40),
                        screen.frame.width * 0.6)
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.minY + 120, width: width, height: 44)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
