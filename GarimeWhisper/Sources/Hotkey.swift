import Carbon.HIToolbox
import Foundation

final class Hotkey {
    static let shared = Hotkey()

    var onTrigger: (() -> Void)?

    fileprivate let signature: OSType = 0x47_57_53_50
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() -> Bool {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &spec,
            nil,
            &handlerRef
        )
        guard installed == noErr else { return false }

        let identifier = EventHotKeyID(signature: signature, id: 1)
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registered == noErr && hotKeyRef != nil
    }

    fileprivate func fire() {
        onTrigger?()
    }
}

private func hotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr, identifier.signature == Hotkey.shared.signature else { return noErr }
    DispatchQueue.main.async { Hotkey.shared.fire() }
    return noErr
}
