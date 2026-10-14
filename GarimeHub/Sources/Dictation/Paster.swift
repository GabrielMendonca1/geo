import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Delivery {
    case pasted
    case copiedOnly(String)
}

final class Paster {
    private static let virtualKeyV = CGKeyCode(kVK_ANSI_V)

    private var promptedForAccessibility = false

    func deliver(_ text: String) -> Delivery {
        if IsSecureEventInputEnabled() {
            copy(text, concealed: true)
            return .copiedOnly("campo seguro — texto no clipboard, cole com ⌘V")
        }
        if focusedElementIsSecure() {
            copy(text, concealed: true)
            return .copiedOnly("campo de senha — texto no clipboard, cole com ⌘V")
        }
        guard AXIsProcessTrusted() else {
            copy(text)
            requestAccessibilityOnce()
            return .copiedOnly("sem Acessibilidade — texto no clipboard, cole com ⌘V")
        }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            copy(text)
            return .copiedOnly("evento indisponível — texto no clipboard, cole com ⌘V")
        }

        let pasteboard = NSPasteboard.general
        let snapshot = capture(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let expected = pasteboard.changeCount

        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Paster.virtualKeyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Paster.virtualKeyV, keyDown: false)
        else {
            return .copiedOnly("evento indisponível — texto no clipboard, cole com ⌘V")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + Config.pasteRestoreDelay) {
            guard pasteboard.changeCount == expected else { return }
            self.restore(snapshot, into: pasteboard)
        }
        return .pasted
    }

    func copy(_ text: String, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard concealed else {
            pasteboard.setString(text, forType: .string)
            return
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
    }

    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibilityOnce() {
        guard !promptedForAccessibility else { return }
        promptedForAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }

    private func capture(_ pasteboard: NSPasteboard) -> [[(type: String, data: Data)]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type: type.rawValue, data: data)
            }
        }
    }

    private func restore(_ snapshot: [[(type: String, data: Data)]], into pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items: [NSPasteboardItem] = snapshot.map { payload in
            let item = NSPasteboardItem()
            for entry in payload {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private func focusedElementIsSecure() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let value = focused,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return false }

        let element = unsafeBitCast(value, to: AXUIElement.self)
        for attribute in [kAXRoleAttribute, kAXSubroleAttribute] {
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { continue }
            if let name = raw as? String, name.contains("SecureTextField") {
                return true
            }
        }
        return false
    }
}
