import AppKit

final class NotchDropView: NSView {
    var onDrop: (([ShelfItem]) -> Void)?
    var onDragEnter: () -> Void = {}
    var onDragExit: () -> Void = {}
    var isActive: Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png, .URL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .tiff, .png, .URL])
        wantsLayer = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive else { return nil }
        let result = super.hitTest(point)
        return result === self ? nil : result
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragExit()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var items: [ShelfItem] = []

        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for url in urls {
                items.append(ShelfItem(url: url))
            }
        } else if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            for img in images {
                items.append(ShelfItem(webImage: img, sourceURL: nil))
            }
        }

        guard !items.isEmpty else { return false }
        onDrop?(items)
        return true
    }
}
