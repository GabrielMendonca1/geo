import Foundation
import AppKit

public extension NSWindow {
    
    var alwaysOnTop: Bool {
        get {
            return level.rawValue >= Int(CGWindowLevelForKey(CGWindowLevelKey.statusWindow))
        }
        set {
            if newValue {
                // Raise the level first
                level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.statusWindow)))
                // Only try to make key if possible; otherwise, just bring it to front
                if self.canBecomeKey {
                    self.makeKeyAndOrderFront(nil)
                } else {
                    self.orderFrontRegardless()
                }
            } else {
                level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(CGWindowLevelKey.normalWindow)))
            }
        }
    }
}
