import AppKit

final class NotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        isFloatingPanel = true
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        level = .statusBar
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
    }

    var canBecomeKeyEnabled = false
    override var canBecomeKey: Bool { canBecomeKeyEnabled }
    override var canBecomeMain: Bool { false }
}
