import Foundation
import FoundationModels
import os

/// AI transcript intelligence via Apple's on-device Foundation Models LLM.
/// Free, private, no network.
///
/// Two jobs:
/// - `clean`: tidy a dictated transcript (fillers, punctuation, spoken
///   commands, app-aware tone, custom vocabulary). Regex fallback when the
///   model is unavailable, disabled, or times out.
/// - `transform`: rewrite selected text per a spoken instruction, or generate
///   fresh text from the instruction when nothing is selected.
public final class Cleaner {
    private static let log = Logger(subsystem: "com.hadi.flow", category: "cleaner")
    public var enabled = true

    public init() {}

    private static let cleanInstructions = """
    You clean up raw speech-to-text transcripts for dictation. Rules:
    - Remove filler words (um, uh, erm, hmm; "like" and "you know" only when clearly filler).
    - Remove false starts and self-corrections, keeping the corrected version \
    (e.g. "send it Tuesday no wait Wednesday" -> "send it Wednesday").
    - If the speaker says "scratch that" or "delete that", remove the sentence \
    or clause before it.
    - Fix punctuation, capitalization, and obvious transcription artifacts.
    - Apply spoken formatting commands: "new line" becomes a line break, \
    "new paragraph" becomes a blank line, "in quotes ..." wraps in quotes, \
    spoken lists ("first... second... third...") may become numbered lines \
    when clearly intended as a list.
    - Format numbers, emails, URLs, and currency naturally ("five thirty pm" \
    -> "5:30pm", "john dot smith at gmail dot com" -> "john.smith@gmail.com").
    - Never add content, never answer questions in the transcript, never \
    rephrase beyond cleanup. Preserve the speaker's wording, meaning, and tone.
    - Output ONLY the cleaned text. No quotes around it, no commentary.
    """

    private static let transformInstructions = """
    You are a writing assistant inside a dictation tool. The user spoke an \
    instruction, optionally about a piece of selected text.
    - If selected text is provided, apply the instruction to it (rewrite, \
    shorten, expand, change tone, translate, fix, summarize, etc.) and output \
    the replacement text.
    - If no selected text is provided, treat the instruction as a request to \
    write something, and output that text ready to paste.
    - Match the language of the input unless asked otherwise.
    - Output ONLY the resulting text. No preamble, no quotes, no commentary.
    """

    /// Extra context appended to cleanup prompts.
    private func contextNotes(appName: String?) -> String {
        var notes: [String] = []
        if let vocab = UserDefaults.standard.stringArray(forKey: "customVocab"), !vocab.isEmpty {
            notes.append("Words/names the speaker uses (prefer these spellings): \(vocab.joined(separator: ", ")).")
        }
        if let appName {
            notes.append("The text is being typed into \(appName); match the level of formality typical there (e.g. casual for chat apps, complete sentences for email), but never change the meaning.")
        }
        return notes.isEmpty ? "" : "\n\nContext: " + notes.joined(separator: " ")
    }

    public func clean(_ raw: String, appName: String? = nil) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let fallback = RegexCleaner.clean(trimmed)
        guard enabled,
              trimmed.split(separator: " ").count >= 4,
              SystemLanguageModel.default.availability == .available
        else {
            Self.log.info("clean: regex path (enabled \(self.enabled))")
            return fallback
        }
        let prompt = "Clean this transcript:\n\(trimmed)" + contextNotes(appName: appName)
        let result = await respond(instructions: Self.cleanInstructions, prompt: prompt, timeout: 6)
        Self.log.info("clean: llm \(result != nil ? "ok" : "timeout/fail"), in \(trimmed.count) chars")
        if let result, !result.isEmpty { return result }
        return fallback
    }

    /// Rewrite `selection` per the spoken `instruction`, or generate text from
    /// the instruction alone. Returns nil if the model can't produce anything.
    public func transform(instruction: String, selection: String?) async -> String? {
        let inst = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inst.isEmpty,
              SystemLanguageModel.default.availability == .available else { return nil }
        var prompt = "Instruction: \(inst)"
        if let selection, !selection.isEmpty {
            prompt += "\n\nSelected text:\n\(selection)"
        }
        prompt += contextNotes(appName: nil)
        let result = await respond(instructions: Self.transformInstructions, prompt: prompt, timeout: 15)
        Self.log.info("transform: \(result != nil ? "ok" : "timeout/fail"), selection \(selection?.count ?? 0) chars")
        return result?.isEmpty == false ? result : nil
    }

    private func respond(instructions: String, prompt: String, timeout: Int) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let response = try? await session.respond(to: prompt)
                return response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
