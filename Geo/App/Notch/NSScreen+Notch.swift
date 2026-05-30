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

struct NotchMetrics {
    let screenFrame: CGRect
    let hasNotch: Bool
    let notchSize: CGSize
    let topInset: CGFloat

    static let cornerRadius: CGFloat = 26
    static let margin: CGFloat = 44
    static let contentHeight: CGFloat = 248
    static let maxDockWidth: CGFloat = 840

    init(screen: NSScreen) {
        screenFrame = screen.frame
        hasNotch = screen.hasPhysicalNotch
        notchSize = screen.effectiveNotchSize
        topInset = screen.hasPhysicalNotch ? screen.effectiveNotchSize.height : screen.menubarHeight
    }

    var dockWidth: CGFloat { min(Self.maxDockWidth, screenFrame.width - 80) }
    var dockHeight: CGFloat { topInset + Self.contentHeight }
    var panelSize: CGSize { CGSize(width: dockWidth + Self.margin * 2, height: dockHeight + Self.margin) }

    var panelFrame: CGRect {
        CGRect(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    var hiddenHoverRect: CGRect {
        let w: CGFloat = hasNotch ? notchSize.width + 40 : 280
        let h: CGFloat = (hasNotch ? notchSize.height : topInset) + 20
        return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }

    var expandedHoverRect: CGRect {
        let w = dockWidth + 80
        let h = dockHeight + 48
        return CGRect(x: screenFrame.midX - w / 2, y: screenFrame.maxY - h, width: w, height: h)
    }
}
