import AppKit
import ScreenCaptureKit
import CoreMedia
import OSLog

final class MacDuoFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var receivedAt: TimeInterval = 0
    private var revision: UInt64 = 0

    func put(_ value: CVPixelBuffer) {
        lock.lock()
        buffer = value
        receivedAt = ProcessInfo.processInfo.systemUptime
        revision &+= 1
        lock.unlock()
    }

    func get() -> (CVPixelBuffer?, TimeInterval, UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (buffer, receivedAt, revision)
    }

    func clear() {
        lock.lock()
        buffer = nil
        receivedAt = 0
        revision &+= 1
        lock.unlock()
    }
}

final class MacDuoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = MacDuoFrameStore()
    private let logger = Logger(subsystem: "ai.garime.whisper", category: "macduo.capture")
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "ai.garime.whisper.macduo.frames", qos: .userInteractive)
    private var generation = 0
    private var starting = false
    private var ownApplication: SCRunningApplication?
    var onFailure: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    private var hasFrame = false
    var isRunning: Bool { stream != nil || starting }

    @MainActor private func availableContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if let own = content.applications.first(where: { $0.processID == getpid() }) {
            ownApplication = own
        }
        return content
    }

    @MainActor func verifyAccess() async throws {
        let content = try await availableContent()
        guard !content.displays.isEmpty else { throw MacDuoError.message("No capturable display is available.") }
        guard ownApplication != nil else { throw MacDuoError.message("Cannot exclude GarimeWhisper from capture. Reopen the app.") }
    }

    @MainActor func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard !isRunning else { return }
        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }
        let available: SCShareableContent
        do { available = try await availableContent() }
        catch {
            guard token == generation else { return }
            throw error
        }
        guard token == generation else { return }
        guard let display = available.displays.first(where: { $0.displayID == displayID }) else {
            throw MacDuoError.message("The built-in display is not available.")
        }
        guard let ownApplication else { throw MacDuoError.message("Cannot exclude GarimeWhisper from capture. Reopen the app.") }
        let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(1, fps)))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = newStream
        do {
            try await newStream.startCapture()
            if token == generation { logger.notice("Live screen stream started.") }
            if token != generation { try? await newStream.stopCapture() }
        } catch {
            guard token == generation else { return }
            stream = nil
            frames.clear()
            throw error
        }
    }

    @MainActor func stop() {
        generation += 1
        starting = false
        let previous = stream
        stream = nil
        frames.clear()
        hasFrame = false
        if let previous { Task { try? await previous.stopCapture() } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let rawStatus = attachments?.first?[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return }
        let buffer = sampleBuffer.imageBuffer
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            if status == .complete, let buffer {
                self.frames.put(buffer)
                if !self.hasFrame {
                    self.hasFrame = true
                    self.onFirstFrame?()
                }
            } else if status == .blank || status == .suspended || status == .stopped {
                self.frames.clear()
                self.hasFrame = false
                self.onUnavailable?()
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.frames.clear()
            self.hasFrame = false
            self.onFailure?(error.localizedDescription)
        }
    }
}
