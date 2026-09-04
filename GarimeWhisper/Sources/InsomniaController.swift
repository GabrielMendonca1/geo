import Foundation
import IOKit.pwr_mgt

final class InsomniaController {
    private var assertion = IOPMAssertionID(0)
    private var manual = false
    private var holds: Set<String> = []
    private let blocker = SleepBlocker()
    private(set) var isActive = false

    var coversClosedLid: Bool { blocker.isBlocking }
    var canCoverClosedLid: Bool { blocker.isAvailable }

    func reconcileOnLaunch() {
        blocker.reconcile(wanted: false)
    }

    var wanted: Bool { manual || !holds.isEmpty }
    var isAutomatic: Bool { !holds.isEmpty && !manual }
    var reasons: [String] { holds.sorted() }

    @discardableResult
    func toggle() -> Bool {
        manual = !wanted
        sync()
        return isActive
    }

    func hold(_ reason: String, on: Bool) {
        if on {
            holds.insert(reason)
        } else {
            holds.remove(reason)
        }
        sync()
    }

    func activate() {
        manual = true
        sync()
    }

    func deactivate() {
        manual = false
        holds.removeAll()
        sync()
    }

    private func sync() {
        if wanted {
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
            blocker.apply(true)
        } else {
            guard isActive else { return }
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(0)
            isActive = false
            blocker.apply(false)
        }
    }

    deinit {
        if isActive {
            IOPMAssertionRelease(assertion)
        }
        blocker.apply(false)
    }
}
