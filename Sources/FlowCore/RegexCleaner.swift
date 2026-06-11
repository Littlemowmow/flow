import Foundation

/// Free, instant transcript cleanup: strips filler words, normalizes spacing,
/// capitalizes the first letter. Used standalone for short utterances and
/// hands-free segments, and as the fallback when the on-device LLM is
/// unavailable or times out.
public enum RegexCleaner {
    private static let fillerPattern = #"(?i)\b(um+|uh+|erm*|hmm+)\b[,.]?"#

    public static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: fillerPattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }
}
