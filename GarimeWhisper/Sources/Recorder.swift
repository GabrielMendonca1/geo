import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case engineFailed(String)
    case routeChanged

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "microfone negado — libere em Ajustes › Privacidade"
        case .noInputDevice: return "nenhum dispositivo de entrada disponível"
        case .engineFailed(let detail): return "falha no áudio: \(detail)"
        case .routeChanged: return "o dispositivo de áudio mudou durante a gravação"
        }
    }
}

final class Recorder {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var url: URL?
    private var startedAt: Date?
    private var routeObserver: NSObjectProtocol?

    var onRouteChange: (() -> Void)?
    var onLevel: ((Float, Float) -> Void)?

    private(set) var stream = StreamBuffer(sampleRate: Config.streamSampleRate)

    var isRecording: Bool { engine != nil }

    static func microphoneAuthorized(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() throws {
        guard engine == nil else { return }
        try FileManager.default.createDirectory(
            atPath: Config.workDirectory,
            withIntermediateDirectories: true
        )
        let target = URL(fileURLWithPath: Config.workDirectory)
            .appendingPathComponent("capture-\(UUID().uuidString).caf")

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: target, settings: format.settings)
        } catch {
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        let sink = stream
        sink.reset()
        let streamFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Config.streamSampleRate,
            channels: 1,
            interleaved: false
        )
        let converter = streamFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        let scratch = streamFormat.flatMap {
            Recorder.makeConversionBuffer(source: format, target: $0, frames: Recorder.tapFrames)
        }

        input.installTap(onBus: 0, bufferSize: Recorder.tapFrames, format: format) { [weak self] buffer, _ in
            try? file.write(from: buffer)
            self?.observe(buffer)
            guard let converter, let scratch else { return }
            Recorder.forward(buffer, converter: converter, output: scratch, into: sink)
        }

        routeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onRouteChange?()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.clearObserver()
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.file = file
        self.url = target
        self.startedAt = Date()
    }

    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let engine, let url else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        clearObserver()
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        self.engine = nil
        self.file = nil
        self.url = nil
        self.startedAt = nil
        return (url, duration)
    }

    private func observe(_ buffer: AVAudioPCMBuffer) {
        guard let handler = onLevel else { return }
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let measurement = LevelMeter.measure(channels[0], count: Int(buffer.frameLength))
        DispatchQueue.main.async { handler(measurement.rms, measurement.peak) }
    }

    static let tapFrames: AVAudioFrameCount = 4096

    static func makeConversionBuffer(
        source: AVAudioFormat,
        target: AVAudioFormat,
        frames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        return AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
    }

    @discardableResult
    static func forward(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        output: AVAudioPCMBuffer,
        into stream: StreamBuffer
    ) -> Bool {
        guard buffer.frameLength > 0 else { return false }
        guard buffer.format.isEqual(converter.inputFormat) else { return false }
        let ratio = output.format.sampleRate / buffer.format.sampleRate
        let produced = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard produced < output.frameCapacity else { return false }

        output.frameLength = 0
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let converted = output.floatChannelData else {
            return false
        }
        stream.append(Array(UnsafeBufferPointer(start: converted[0], count: Int(output.frameLength))))
        return true
    }

    func abort() {
        if let result = stop() {
            try? FileManager.default.removeItem(at: result.url)
        }
    }

    private func clearObserver() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        routeObserver = nil
    }
}
