import Speech
import AVFoundation
import os

/// On-device speech-to-text via macOS 26's SpeechAnalyzer/SpeechTranscriber.
/// One instance per app; a fresh analyzer session is created per dictation.
public final class Transcriber {
    private static let log = Logger(subsystem: "com.hadi.flow", category: "transcriber")
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private var finalized = ""

    /// Full running text including the volatile tail (for the HUD).
    public var onVolatile: ((String) -> Void)?
    /// Each finalized segment as it lands (for hands-free live typing).
    public var onFinalSegment: ((String) -> Void)?

    public init() {}

    /// Download the on-device model assets if missing.
    public static func ensureModel() async throws {
        let t = SpeechTranscriber(locale: .current, transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try await request.downloadAndInstall()
        }
    }

    public func start() async throws {
        finalized = ""
        let t = SpeechTranscriber(locale: .current, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults], attributeOptions: [])
        transcriber = t
        let a = SpeechAnalyzer(modules: [t])
        analyzer = a
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        Self.log.info("session start, analyzerFormat \(self.analyzerFormat != nil ? "ok" : "NIL — no audio will be fed")")
        converter = nil
        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        resultsTask = Task { [weak self] in
            do {
                for try await result in t.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    Self.log.debug("result isFinal=\(result.isFinal) len=\(text.count)")
                    if result.isFinal {
                        self.finalized += text
                        self.onFinalSegment?(text)
                        self.onVolatile?(self.finalized)
                    } else {
                        self.onVolatile?(self.finalized + text)
                    }
                }
            } catch { /* session ended or cancelled */ }
        }
        try await a.start(inputSequence: sequence)
    }

    public func feed(_ buffer: AVAudioPCMBuffer) {
        guard let format = analyzerFormat else { return }
        if buffer.format == format {
            inputBuilder?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let converter,
              let out = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(ratio * Double(buffer.frameLength)) + 16)
        else { return }
        var err: NSError?
        var fed = false
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil, out.frameLength > 0 {
            inputBuilder?.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Finish the session and return the complete finalized transcript.
    public func stop() async -> String {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        let result = finalized
        Self.log.info("session stop, finalized \(result.count) chars")
        teardown()
        return result
    }

    /// Abort, discarding the transcript (Esc in hands-free).
    public func cancel() async {
        inputBuilder?.finish()
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        teardown()
    }

    private func teardown() {
        analyzer = nil
        transcriber = nil
        inputBuilder = nil
        converter = nil
        resultsTask = nil
        finalized = ""
    }
}
