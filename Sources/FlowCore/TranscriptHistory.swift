import Foundation

/// Newest-first ring buffer of recent transcripts, shown in the menu.
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
