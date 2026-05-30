import AppKit

@MainActor
final class NotchDropZonePanel {
    private var panel: NSPanel?
    private var dropView: DropZoneView?

    func show(on screen: NSScreen, stateStore: NotchStateStore) {
        let notchWidth = screen.hasPhysicalNotch ? screen.effectiveNotchSize.width : CGFloat(200)
        let notchHeight = screen.hasPhysicalNotch ? screen.effectiveNotchSize.height : screen.menubarHeight
        let zoneWidth = notchWidth + 20
        let zoneHeight = notchHeight + 20
        let origin = NSPoint(
            x: screen.frame.midX - zoneWidth / 2,
            y: screen.frame.maxY - zoneHeight
        )
        let rect = NSRect(origin: origin, size: CGSize(width: zoneWidth, height: zoneHeight))

        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.hasShadow = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = DropZoneView(frame: NSRect(origin: .zero, size: CGSize(width: zoneWidth, height: zoneHeight)))
        view.onDragEnter = { [weak stateStore] in
            Task { @MainActor in stateStore?.dragEntered() }
        }
        view.onDragExit = { [weak stateStore] in
            Task { @MainActor in stateStore?.dragExited() }
        }
        view.onDrop = { [weak stateStore] items in
            Task { @MainActor in
                stateStore?.dragExited()
                for item in items { ShelfStore.shared.addItem(item) }
                stateStore?.forceExpand()
            }
        }

        p.contentView = view
        p.orderFrontRegardless()

        panel = p
        dropView = view
    }

    func hide() {
        panel?.close()
        panel = nil
        dropView = nil
    }
}

final class DropZoneView: NSView {
    var onDrop: (([ShelfItem]) -> Void)?
    var onDragEnter: () -> Void = {}
    var onDragExit: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png, .URL])
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragExit() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var items: [ShelfItem] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            for url in urls { items.append(ShelfItem(url: url)) }
        } else if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            for img in images { items.append(ShelfItem(webImage: img, sourceURL: nil)) }
        }
        guard !items.isEmpty else { return false }
        onDrop?(items)
        return true
    }
}
