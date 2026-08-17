import Foundation
import IOKit.pwr_mgt

final class InsomniaController {
    private var assertion = IOPMAssertionID(0)
    private(set) var isActive = false

    @discardableResult
    func toggle() -> Bool {
        if isActive {
            deactivate()
        } else {
            activate()
        }
        return isActive
    }

    func activate() {
        guard !isActive else { return }
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Garime Whisper mantém o Mac acordado" as CFString,
            &id
        )
        guard status == kIOReturnSuccess else { return }
        assertion = id
        isActive = true
    }

    func deactivate() {
        guard isActive else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(0)
        isActive = false
    }

    deinit {
        if isActive {
            IOPMAssertionRelease(assertion)
        }
    }
}
