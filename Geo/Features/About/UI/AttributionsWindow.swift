import Cocoa
import SwiftUI

// AttributionsWindow displays a window with attributions (credits/licensing) info for your app.
class AttributionsWindow: NSWindowController {
    
    // Opens the Attributions window. This class method allows you to show the window from anywhere.
    static func show() {
        // Create a new AttributionsWindow instance and bring its window to the front.
        AttributionsWindow().window?.makeKeyAndOrderFront(nil)
    }

    // Convenience initializer to configure the window and its SwiftUI content.
    convenience init() {
        // Create and configure the window itself.
        let window = Self.makeWindow()
        
        // Set the window's background color to the system control background.
        window.backgroundColor = NSColor.controlBackgroundColor
        
        // Call the superclass convenience init with our configured window.
        self.init(window: window)

        // Create the SwiftUI content view that will fill the window.
        let contentView = AttributionsView()
            .frame(minWidth: 500, minHeight: 300) // Minimum window size
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Expand as window grows

        // Visual tweaks for a modern floating panel-style appearance.
        window.titleVisibility = .hidden               // Hide the standard window title
        window.titlebarAppearsTransparent = true       // Make the title bar blend into the content
        window.center()                                // Center the window on the screen
        window.title = "Attributions"                  // (Hidden, but good for accessibility)
        // Bridge our SwiftUI view into AppKit's window system.
        window.contentView = NSHostingView(rootView: contentView)
        // Keep this window above other windows.
        window.alwaysOnTop = true
    }
    
    // Helper to create the NSWindow with the right size and features.
    private static func makeWindow() -> NSWindow {
        let contentRect = NSRect(x: 0, y: 0, width: 500, height: 300) // Initial size of the window
        // Style masks control the window's abilities and appearance.
        let styleMask: NSWindow.StyleMask = [
            .titled,                // Show a title bar (even if the title is hidden)
            .miniaturizable,        // Allow minimizing to the Dock
            .resizable,             // Allow resizing
            .closable,              // Show a close button
            .fullSizeContentView    // Let content go under the title bar
        ]
        // Create and return the NSWindow configured with these options.
        return NSWindow(contentRect: contentRect,
                        styleMask: styleMask,
                        backing: .buffered, // Use a buffered window for smooth rendering
                        defer: false)       // Create immediately
    }
}
