import Foundation
import FoundationModels

/// AI transcript cleanup via Apple's on-device Foundation Models LLM.
/// Free, private, no network. Falls back to RegexCleaner when disabled,
/// for short utterances (latency not worth it), when Apple Intelligence
/// is unavailable, or on timeout.
public final class Cleaner {
    public var enabled = true

    private static let instructions = """
    You clean up raw speech-to-text transcripts for dictation. Rules:
    - Remove filler words (um, uh, erm, hmm; "like" and "you know" only when clearly filler).
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

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: Self.instructions)
                let response = try? await session.respond(to: "Clean this transcript:\n\(trimmed)")
                return response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(6))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let result, !result.isEmpty { return result }
        return fallback
    }
}
