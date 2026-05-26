import AppKit
import Foundation

protocol AttachmentService: Sendable {
    func ensureDirectory(at directory: URL) -> Bool
    func copyAttachment(from source: URL, to directory: URL) -> URL?
    func saveImage(_ image: NSImage, to directory: URL) -> URL?
    func saveImageData(_ data: Data, extension ext: String, to directory: URL) -> URL?
    func uniqueURL(for fileName: String, in directory: URL) -> URL
    func deleteAttachmentsDirectory(for blockURL: URL)
    func deleteAttachment(relativePath: String, baseDirectory: URL)
}
