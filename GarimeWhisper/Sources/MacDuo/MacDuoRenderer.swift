import AppKit
import MetalKit
import CoreVideo

struct MacDuoUniforms: Equatable {
    var progress: Float = 0
    var perspective: Float = 0.7
    var blur: Float = 0.65
    var shadow: Float = 0.65
    var size = SIMD2<Float>(1, 1)
    var fadeOnly: Float = 0
    var effect: UInt32 = MacDuoEffect.fallback.shaderIndex

    var selectedEffect: MacDuoEffect { MacDuoEffect.resolve(shaderIndex: effect) }
}

final class MacDuoRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private var blurPyramid: MTLTexture?
    private var blurLevels: [MTLTexture] = []
    private var blurredRevision: UInt64?
    private var renderedRevision: UInt64?
    private var renderedUniforms: MacDuoUniforms?
    private var cache: CVMetalTextureCache?
    private let inFlight = DispatchSemaphore(value: 3)
    var frames: MacDuoFrameStore?
    var fallback: MTLTexture?
    var parameters: () -> MacDuoUniforms = { MacDuoUniforms() }
    var animatedProgress: (() -> Double?)?
    var pausesWhenSettled = false
    var keepsAnimating: () -> Bool = { false }
    var onFailure: ((String) -> Void)?
    var onPresented: (() -> Void)?
    private(set) var progress: Double = 0
    private var lastTime = ProcessInfo.processInfo.systemUptime
    private(set) var drawnFrames = 0
    private(set) var skippedFrames = 0
    private(set) var blurBuildCount = 0
    private(set) var lastGPUTimeMS: Double = 0

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw MacDuoError.message("Metal command queue unavailable.") }
        self.queue = queue
        let library = try device.makeLibrary(source: MacDuoShader.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let downsample = library.makeFunction(name: "foldDownsample") else {
            throw MacDuoError.message("Blur shader unavailable.")
        }
        downsamplePipeline = try device.makeComputePipelineState(function: downsample)
        super.init()
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw MacDuoError.message("Metal texture cache unavailable.")
        }
    }

    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = self
        view.isPaused = false
        view.enableSetNeedsDisplay = true
    }

    func resetProgress(to value: Double) {
        progress = value
        lastTime = ProcessInfo.processInfo.systemUptime
        renderedUniforms = nil
    }

    func wake(_ view: MTKView) {
        guard view.window?.occlusionState.contains(.visible) == true else { return }
        if view.isPaused { lastTime = ProcessInfo.processInfo.systemUptime }
        view.isPaused = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderedUniforms = nil }

    func draw(in view: MTKView) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard view.window?.isVisible == true, inFlight.wait(timeout: .now()) == .success else { return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        var cvTexture: CVMetalTexture?
        let frame = frames?.get()
        let pixelBuffer = frame?.0
        let revision = pixelBuffer == nil ? 0 : frame!.2
        var texture = fallback
        if let pixelBuffer, let cache {
            let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer,
                nil, .bgra8Unorm, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
            if result == kCVReturnSuccess, let cvTexture { texture = CVMetalTextureGetTexture(cvTexture) }
        }
        guard let texture else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var uniforms = parameters()
        let target = Double(uniforms.progress)
        progress = animatedProgress?() ?? MacDuoMath.smooth(current: progress, target: target, dt: min(0.1, now - lastTime))
        lastTime = now
        uniforms.progress = Float(progress)
        uniforms.size = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let settled = abs(progress - target) < 0.0001 && !keepsAnimating()
        if renderedRevision == revision && renderedUniforms == uniforms {
            skippedFrames += 1
            if pausesWhenSettled && settled { view.isPaused = true }
            return
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        do { try encode(command: command, pass: pass, texture: texture, uniforms: uniforms, sourceRevision: revision) }
        catch {
            blurredRevision = nil
            renderedUniforms = nil
            onFailure?(error.localizedDescription)
            return
        }
        let retainedTexture = cvTexture
        command.addCompletedHandler { [weak self, inFlight, pixelBuffer, retainedTexture] buffer in
            withExtendedLifetime((pixelBuffer, retainedTexture)) {}
            inFlight.signal()
            DispatchQueue.main.async {
                guard let self else { return }
                if buffer.status == .error {
                    self.blurredRevision = nil
                    self.renderedUniforms = nil
                    self.onFailure?(buffer.error?.localizedDescription ?? "Metal rendering failed.")
                }
                self.lastGPUTimeMS = max(0, (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                if buffer.status == .completed { self.onPresented?() }
            }
        }
        command.present(drawable)
        committed = true
        command.commit()
        drawnFrames += 1
        renderedRevision = revision
        renderedUniforms = uniforms
        if pausesWhenSettled && settled { view.isPaused = true }
    }

    private func prepareBlur(command: MTLCommandBuffer, input: MTLTexture, revision: UInt64?) throws -> MTLTexture {
        if blurPyramid?.width != input.width || blurPyramid?.height != input.height || blurPyramid?.pixelFormat != input.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: input.pixelFormat,
                width: input.width, height: input.height, mipmapped: true)
            descriptor.mipmapLevelCount = min(9, descriptor.mipmapLevelCount)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw MacDuoError.message("Blur texture allocation failed.")
            }
            var levels: [MTLTexture] = []
            for level in 0..<texture.mipmapLevelCount {
                guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                    levels: level..<(level + 1), slices: 0..<1) else { throw MacDuoError.message("Blur level unavailable.") }
                levels.append(view)
            }
            blurPyramid = texture
            blurLevels = levels
            blurredRevision = nil
        }
        if let revision, blurredRevision == revision, let pyramid = blurPyramid { return pyramid }
        guard let pyramid = blurPyramid, let blit = command.makeBlitCommandEncoder() else {
            throw MacDuoError.message("Blur copy encoder unavailable.")
        }
        blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: input.width, height: input.height, depth: 1),
            to: pyramid, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        for level in 1..<blurLevels.count {
            guard let encoder = command.makeComputeCommandEncoder() else { throw MacDuoError.message("Blur encoder unavailable.") }
            encoder.setComputePipelineState(downsamplePipeline)
            encoder.setTexture(blurLevels[level - 1], index: 0)
            encoder.setTexture(blurLevels[level], index: 1)
            encoder.dispatchThreads(MTLSize(width: blurLevels[level].width, height: blurLevels[level].height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
        blurredRevision = revision
        blurBuildCount += 1
        return pyramid
    }

    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, texture: MTLTexture,
                uniforms: MacDuoUniforms, sourceRevision: UInt64? = nil) throws {
        let moving = uniforms.progress > 0.00001 && uniforms.progress < 1 && uniforms.fadeOnly < 0.5
        let needsBlur = moving && (uniforms.blur > 0 || uniforms.selectedEffect.needsPrefilteredSource)
        let blurred = needsBlur ? try prepareBlur(command: command, input: texture, revision: sourceRevision) : texture
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw MacDuoError.message("Render encoder unavailable.")
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(blurred, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MacDuoUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    func renderOffscreen(source: MTLTexture, uniforms: MacDuoUniforms, revision: UInt64? = nil) throws -> (texture: MTLTexture, gpuMilliseconds: Double) {
        let width = Int(uniforms.size.x) > 0 ? Int(uniforms.size.x) : source.width
        let height = Int(uniforms.size.y) > 0 ? Int(uniforms.size.y) : source.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw MacDuoError.message("Offscreen target unavailable.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        var uniforms = uniforms
        uniforms.size = SIMD2(Float(width), Float(height))
        try encode(command: command, pass: pass, texture: source, uniforms: uniforms, sourceRevision: revision)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw MacDuoError.message("Offscreen rendering failed.") }
        lastGPUTimeMS = max(0, (command.gpuEndTime - command.gpuStartTime) * 1000)
        return (target, lastGPUTimeMS)
    }

    func makeSyntheticFrame() throws -> CVPixelBuffer {
        let input = try makePreviewTexture()
        let w = input.width
        let h = input.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw MacDuoError.message("Cannot create the overlay test frame.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try encode(command: command, pass: pass, texture: input, uniforms: MacDuoUniforms())
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw MacDuoError.message("Test frame rendering failed.") }
        var pixel: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { throw MacDuoError.message("Test pixel buffer unavailable.") }
        CVPixelBufferLockBaseAddress(pixel, [])
        target.getBytes(CVPixelBufferGetBaseAddress(pixel)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                        from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }

    func makePreviewTexture(width: Int = 1440, height: Int = 936) throws -> MTLTexture {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MacDuoError.message("Preview image could not be created.")
        }
        context.scaleBy(x: CGFloat(width) / 1440, y: CGFloat(height) / 936)
        let colors = [NSColor(red: 0.07, green: 0.13, blue: 0.18, alpha: 1).cgColor,
                      NSColor(red: 0.18, green: 0.47, blue: 0.48, alpha: 1).cgColor,
                      NSColor(red: 0.89, green: 0.68, blue: 0.48, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.6, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 720, y: 936), end: CGPoint(x: 720, y: 0), options: [])
        for i in 0..<6 {
            let path = CGMutablePath()
            let y = Double(i) * 60
            path.move(to: CGPoint(x: 0, y: y))
            path.addCurve(to: CGPoint(x: 1440, y: y + 190), control1: CGPoint(x: 480, y: y + 430), control2: CGPoint(x: 1000, y: y - 180))
            path.addLine(to: CGPoint(x: 1440, y: 0))
            path.addLine(to: .zero)
            path.closeSubpath()
            context.setFillColor(NSColor(red: 0.06, green: 0.19 + Double(i) * 0.012, blue: 0.24 + Double(i) * 0.012, alpha: 0.30).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 116, weight: .light),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
        let caption: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23, weight: .medium),
                                                      .foregroundColor: NSColor.white.withAlphaComponent(0.8)]
        let previewTitle = "Mac Duo" as NSString
        let titleWidth = previewTitle.size(withAttributes: title).width
        previewTitle.draw(at: CGPoint(x: (1440 - titleWidth) / 2, y: 530), withAttributes: title)
        ("A little motion. A different feeling." as NSString).draw(at: CGPoint(x: 533, y: 493), withAttributes: caption)
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: NSRect(x: 490, y: 28, width: 460, height: 78), xRadius: 23, yRadius: 23).fill()
        for i in 0..<7 {
            NSColor(calibratedHue: CGFloat(i) / 9, saturation: 0.35, brightness: 0.95, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: NSRect(x: 511 + i * 62, y: 41, width: 49, height: 49), xRadius: 13, yRadius: 13).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw MacDuoError.message("Preview image is unavailable.") }
        return try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
    }
}
