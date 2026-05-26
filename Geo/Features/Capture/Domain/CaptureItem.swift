import Foundation
import AppKit

struct CaptureItem: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    let extractedText: String?
    let sourceURL: URL?
    let previewData: Data?
    let imageData: Data?
    var dayId: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String,
        extractedText: String?,
        sourceURL: URL?,
        previewData: Data?,
        imageData: Data?,
        dayId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.extractedText = extractedText
        self.sourceURL = sourceURL
        self.previewData = previewData
        self.imageData = imageData
        self.dayId = dayId
    }

    func fullImageData() -> Data? {
        if let sourceURL, let data = try? Data(contentsOf: sourceURL) {
            return data
        }
        return imageData
    }

    func fullImage() -> NSImage? {
        guard let data = fullImageData() else { return nil }
        return NSImage(data: data)
    }

    var previewImage: NSImage? {
        guard let previewData else { return nil }
        return NSImage(data: previewData)
    }
}
