//
//  OCRService.swift
//  Geo
//
//  Created by Biel on 21/11/25.
//
import Vision
import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "OCRService")

class OCRService {
    static let shared = OCRService()

    private let queue = DispatchQueue(label: "com.sidebarapp.ocr", qos: .userInteractive, attributes: .concurrent)
    private let timeout: TimeInterval = 8

    private init() {}

    func process(_ image: NSImage, completion: @escaping (String) -> Void) {
        guard let baseImage = cgImage(from: image) else {
            logger.error("Failed to create CGImage from NSImage")
            completion("")
            return
        }
        let cgImage = scaleIfNeeded(baseImage)

        let finished = NSLock()
        var didFinish = false
        let deliver: (String) -> Void = { text in
            finished.lock()
            let already = didFinish
            didFinish = true
            finished.unlock()
            if already { return }
            DispatchQueue.main.async { completion(text) }
        }

        let request = self.makeRequest()
        queue.async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
                let observations = request.results ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                deliver(text)
            } catch {
                logger.error("Failed with error \(error.localizedDescription)")
                deliver("")
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) {
            finished.lock()
            let already = didFinish
            finished.unlock()
            if !already {
                logger.warning("OCR timed out after \(Int(self.timeout))s; abandoning request")
                deliver("")
            }
        }
    }
    
    private func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest { _, _ in }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.preferBackgroundProcessing = false
        if #available(macOS 14, *) {
            request.revision = VNRecognizeTextRequestRevision3
        } else {
            request.revision = VNRecognizeTextRequest.currentRevision
        }
        // Respect user's preferred languages; fall back to English.
        let preferred = Locale.preferredLanguages.compactMap { identifier -> String? in
            let locale = Locale(identifier: identifier)
            guard let language = locale.language.languageCode?.identifier else { return nil }
            if let region = locale.region?.identifier {
                return "\(language)-\(region)"
            }
            return language
        }
        request.recognitionLanguages = preferred.isEmpty ? ["en-US"] : preferred
        return request
    }
    
    private func scaleIfNeeded(_ cgImage: CGImage, maxDimension: CGFloat = 3000) -> CGImage {
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        let maxSide = max(w, h)
        guard maxSide > maxDimension else { return cgImage }
        let scale = maxDimension / maxSide
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return cgImage }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? cgImage
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        // Try the native conversion first.
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        
        // Fall back to any bitmap representation the image might have.
        for rep in image.representations {
            if let bitmapRep = rep as? NSBitmapImageRep, let cg = bitmapRep.cgImage {
                return cg
            }
        }
        
        // Last resort: rebuild from TIFF data.
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let cg = bitmap.cgImage {
            return cg
        }
        
        return nil
    }
}
