import Carbon.HIToolbox
import Foundation

final class Hotkey {
    static let shared = Hotkey()

    var onTrigger: (() -> Void)?

    let signature: OSType = 0x47_57_53_50
    let identifierID: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register() -> Bool {
        if hotKeyRef != nil, handlerRef != nil { return true }
        unregister()
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

        let identifier = EventHotKeyID(signature: signature, id: identifierID)
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registered == noErr, hotKeyRef != nil else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    func handle(_ identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == signature, identifier.id == identifierID else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async { Hotkey.shared.fire() }
        return noErr
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
    guard let event,
          GetEventClass(event) == OSType(kEventClassKeyboard),
          GetEventKind(event) == UInt32(kEventHotKeyPressed)
    else { return OSStatus(eventNotHandledErr) }

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
    guard status == noErr else { return OSStatus(eventNotHandledErr) }
    return Hotkey.shared.handle(identifier)
}
