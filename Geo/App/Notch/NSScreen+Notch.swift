import AppKit

extension NSScreen {
    static var preferred: NSScreen? {
        screenWithMouse ?? NSScreen.main ?? NSScreen.screens.first
    }

    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    var hasPhysicalNotch: Bool {
        auxiliaryTopLeftArea?.width != nil && auxiliaryTopRightArea?.width != nil
    }

    var physicalNotchSize: NSSize? {
        guard let l = auxiliaryTopLeftArea?.width,
              let r = auxiliaryTopRightArea?.width else { return nil }
        return NSSize(width: frame.width - l - r, height: safeAreaInsets.top)
    }

    var menubarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    var effectiveNotchSize: NSSize {
        physicalNotchSize ?? NSSize(width: 220, height: max(menubarHeight, 24))
    }
}
