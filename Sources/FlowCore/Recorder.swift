import AVFoundation

/// Streams microphone buffers to a consumer. No temp files.
public final class Recorder {
    private let engine = AVAudioEngine()
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    public init() {}

    public func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
