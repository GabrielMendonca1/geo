import SwiftUI
import AppKit

/// The WindowReflection is a view that peeks behind the curtain and finds the underlying NSWindow.
///
/// ```
/// .background(WindowReflection(window: $window))
/// ```
public struct WindowReflection: NSViewRepresentable {
    
    @Binding var window: NSWindow?
    
    public func makeNSView(context: Context) -> NSView {
        let view = WindowAccessorView()
        view.onWindowChange = { [weak view] in
            self.window = view?.window
        }
        return view
    }
    
    public func updateNSView(_ nsView: NSView, context: Context) {}
}

private class WindowAccessorView: NSView {
    var onWindowChange: (() -> Void)?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Defer the update to the next runloop to avoid state changes during layout
        DispatchQueue.main.async {
            self.onWindowChange?()
        }
    }
}
