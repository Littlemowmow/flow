import Testing
@testable import FlowCore

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
