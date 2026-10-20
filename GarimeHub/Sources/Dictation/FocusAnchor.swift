import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class SystemFocusGate: FocusGate {
    private var anchoredPid: pid_t?
    private var anchoredElement: AXUIElement?

    var isAvailable: Bool { AXIsProcessTrusted() }

    var isSecure: Bool {
        if IsSecureEventInputEnabled() { return true }
        guard let element = focusedElement() else { return false }
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
                continue
            }
            if let name = raw as? String, name.contains("SecureTextField") { return true }
        }
        return false
    }

    func anchor() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }
        anchoredPid = pid
        anchoredElement = focusedElement()
        if anchoredElement == nil {
            SystemFocusGate.exposeAccessibility(of: pid)
            anchoredElement = focusedElement()
        }
        return true
    }

    func stillFocused() -> Bool {
        guard let anchoredPid else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == anchoredPid else {
            return false
        }
        guard let anchoredElement, let current = focusedElement() else { return true }
        return CFEqual(current, anchoredElement)
    }

    static func exposeAccessibility(of pid: pid_t) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    func release() {
        anchoredPid = nil
        anchoredElement = nil
    }

    private func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let value = focused,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
