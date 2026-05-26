import Foundation
import AppKit

enum NanoAttachmentKind: Sendable, Equatable {
    case image(NSImage, fileName: String)
    case file(URL)
}

struct NanoAttachment: Identifiable, Equatable {
    let id: UUID
    let kind: NanoAttachmentKind

    init(id: UUID = UUID(), kind: NanoAttachmentKind) {
        self.id = id
        self.kind = kind
    }

    var fileName: String {
        switch kind {
        case .image(_, let name): return name
        case .file(let url): return url.lastPathComponent
        }
    }

    var icon: String {
        switch kind {
        case .image: return "photo"
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" { return "doc.richtext" }
            if ["md", "txt"].contains(ext) { return "doc.text" }
            if ["json", "yaml", "yml", "toml"].contains(ext) { return "doc.text.fill" }
            if ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) { return "photo" }
            if ["mp4", "mov", "avi", "mkv"].contains(ext) { return "film" }
            return "doc"
        }
    }

    static func == (lhs: NanoAttachment, rhs: NanoAttachment) -> Bool { lhs.id == rhs.id }
}
