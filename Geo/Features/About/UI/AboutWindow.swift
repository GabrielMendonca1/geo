import AppKit
import SwiftUI

// AboutWindow manages the "About" window for the app, presenting information about the application.
class AboutWindow: NSWindowController {
    
    // Shows the About window.
    static func show() {
        // Create and display the window. "makeKeyAndOrderFront(nil)" brings it to the front.
        AboutWindow().window?.makeKeyAndOrderFront(nil)
    }

    // Convenience initializer to set up the window and its content.
    convenience init() {
        // Create the NSWindow instance with the required style and size.
        let window = Self.makeWindow()
        
        // Set the background color to the system's control background color.
        window.backgroundColor = NSColor.controlBackgroundColor
        
        // Initialize the superclass (NSWindowController) with the window.
        self.init(window: window)

        // Create the SwiftUI view for the about content.
        let contentView = makeAboutView()
        
        // Hide the window title and use a transparent title bar for a modern look.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        
        // Center the window on the screen.
        window.center()
        
        // Set the (still technically present) title for accessibility and other uses.
        window.title = "About Geo"
        
        // Set the contentView of the window to a SwiftUI view via NSHostingView.
        window.contentView = NSHostingView(rootView: contentView)
        
        // Keep this window always above others.
        window.alwaysOnTop = true
    }
    
    // Constructs and returns a new NSWindow configured for the About window.
    private static func makeWindow() -> NSWindow {
        // Set the window size and position; values are in points.
        let contentRect = NSRect(x: 0, y: 0, width: 600, height: 360)
        // StyleMask determines the window's appearance and capabilities.
        let styleMask: NSWindow.StyleMask = [
            .titled,        // Has a title bar.
            .closable,      // Can be closed by the user.
            .fullSizeContentView // Allows the content view to extend into the title bar area.
        ]
        // Create the window with the above parameters.
        return NSWindow(contentRect: contentRect,
                        styleMask: styleMask,
                        backing: .buffered, // Backed by a buffered graphics context.
                        defer: false) // Create immediately (not deferred).
    }

    // Builds the AboutView, passing in app details from the bundle.
    private func makeAboutView() -> some View {
        AboutView(
            // The app's icon, defaulting to an empty NSImage if unavailable.
            icon: NSApp.applicationIconImage ?? NSImage(),
            // Name, version, build info, copyright, etc.
            name: Bundle.main.name,
            version: Bundle.main.version,
            build: Bundle.main.buildVersion,
            copyright: Bundle.main.copyright,
            developerName: "G") // Replace with your actual name.
            .frame(width: 600, height: 360) // Fix the SwiftUI view size to match the window.
    }
}
