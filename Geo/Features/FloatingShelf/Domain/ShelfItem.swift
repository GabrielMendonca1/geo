import Foundation
import AppKit
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Equatable {
    let id: UUID
    let url: URL?
    let image: NSImage?
    let name: String
    let type: ItemType
    let dateAdded: Date
    let didStartAccessing: Bool

    enum ItemType: Equatable {
        case file
        case folder
        case image
        case webImage

        var icon: String {
            switch self {
            case .folder: return "folder.fill"
            case .image, .webImage: return "photo.fill"
            case .file: return "doc.fill"
            }
        }
    }

    init(url: URL, didStartAccessing: Bool = false) {
        self.id = UUID()
        self.url = url
        self.dateAdded = Date()
        self.didStartAccessing = didStartAccessing

        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .localizedNameKey])
        self.name = resourceValues?.localizedName ?? url.lastPathComponent

        if resourceValues?.isDirectory == true {
            self.type = .folder
            self.image = NSWorkspace.shared.icon(forFile: url.path)
        } else if let uti = UTType(filenameExtension: url.pathExtension),
                  uti.conforms(to: .image),
                  let img = NSImage(contentsOf: url) {
            self.type = .image
            self.image = img
        } else {
            self.type = .file
            self.image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    init(webImage: NSImage, sourceURL: URL?) {
        self.id = UUID()
        self.url = sourceURL
        self.image = webImage
        self.name = sourceURL?.lastPathComponent ?? "Web Image"
        self.type = .webImage
        self.dateAdded = Date()
        self.didStartAccessing = false
    }

    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool {
        lhs.id == rhs.id
    }
}
