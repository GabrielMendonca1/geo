import Carbon.HIToolbox
import Foundation

final class FilesSelectionHotKeys {
    enum Action: UInt32, Equatable {
        case convert = 1
        case tools = 2
    }

    struct Binding: Equatable {
        let action: Action
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static let approvedBindings = [
        Binding(
            action: .convert,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        ),
        Binding(
            action: .tools,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(shiftKey | controlKey | optionKey)
        ),
    ]

    var onConvert: (() -> Void)?
    var onTools: (() -> Void)?
    private(set) var registrationError: String?

    fileprivate let signature: OSType = 0x54_53_45_4C
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    @discardableResult
    func register() -> Bool {
        if handlerRef != nil, hotKeyRefs.count == Self.approvedBindings.count {
            registrationError = nil
            return true
        }
        unregister()
        registrationError = nil

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            filesSelectionHotKeyHandler,
            1,
            &spec,
            context,
            &handlerRef
        )
        guard installed == noErr, handlerRef != nil else {
            registrationError = "não foi possível instalar o receptor de atalhos (código \(installed))"
            unregister(preservingError: true)
            return false
        }

        for binding in Self.approvedBindings {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: signature, id: binding.action.rawValue)
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard status == noErr, let reference else {
                registrationError = "o atalho \(label(for: binding.action)) já está em uso (código \(status))"
                unregister(preservingError: true)
                return false
            }
            hotKeyRefs.append(reference)
        }
        return true
    }

    func unregister() {
        unregister(preservingError: false)
    }

    private func unregister(preservingError: Bool) {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRefs.removeAll()
        handlerRef = nil
        if !preservingError { registrationError = nil }
    }

    fileprivate func handle(_ identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == signature,
              let action = Action(rawValue: identifier.id),
              Self.approvedBindings.contains(where: { $0.action == action })
        else { return OSStatus(eventNotHandledErr) }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.handlerRef != nil else { return }
            switch action {
            case .convert: self.onConvert?()
            case .tools: self.onTools?()
            }
        }
        return noErr
    }

    private func label(for action: Action) -> String {
        switch action {
        case .convert: return "⌃⌥Space"
        case .tools: return "⇧⌃⌥Space"
        }
    }
}

private func filesSelectionHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context,
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
    let owner = Unmanaged<FilesSelectionHotKeys>.fromOpaque(context).takeUnretainedValue()
    return owner.handle(identifier)
}
