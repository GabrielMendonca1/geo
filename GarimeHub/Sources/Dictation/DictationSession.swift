import Foundation

protocol TextSink: AnyObject {
    func emit(_ text: String) -> Bool
}

protocol FocusGate: AnyObject {
    var isAvailable: Bool { get }
    var isSecure: Bool { get }
    func anchor() -> Bool
    func stillFocused() -> Bool
    func release()
}

enum LatchReason: Equatable {
    case unavailable
    case secure
    case focusLost
    case insertFailed

    var message: String {
        switch self {
        case .unavailable: return "sem Acessibilidade — texto no clipboard, cole com ⌘V"
        case .secure: return "campo seguro — texto no clipboard, cole com ⌘V"
        case .focusLost: return "o foco mudou — resto no clipboard, cole com ⌘V"
        case .insertFailed: return "inserção falhou — resto no clipboard, cole com ⌘V"
        }
    }
}

enum InjectionOutcome: Equatable {
    case typed(String)
    case skipped
    case latched(LatchReason)
}

enum FinalOutcome: Equatable {
    case typed(String)
    case clipboard(text: String, reason: LatchReason)
    case nothing
    case duplicate
}

final class DictationSession {
    let generation: Int

    private let sink: TextSink
    private let gate: FocusGate
    private let lock = NSLock()

    private var transcriptStorage = ""
    private var typedStorage = ""
    private var latchStorage: LatchReason?
    private var finished = false
    private var active = true

    init(generation: Int, sink: TextSink, gate: FocusGate) {
        self.generation = generation
        self.sink = sink
        self.gate = gate
    }

    var transcript: String {
        lock.lock()
        defer { lock.unlock() }
        return transcriptStorage
    }

    var typedText: String {
        lock.lock()
        defer { lock.unlock() }
        return typedStorage
    }

    var latch: LatchReason? {
        lock.lock()
        defer { lock.unlock() }
        return latchStorage
    }

    var isLatched: Bool { latch != nil }

    @discardableResult
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard gate.isAvailable else {
            latchStorage = .unavailable
            return false
        }
        guard gate.anchor() else {
            latchStorage = .focusLost
            return false
        }
        return true
    }

    func ingest(_ delta: String, generation token: Int) -> InjectionOutcome {
        lock.lock()
        guard active, !finished, token == generation, !delta.isEmpty else {
            lock.unlock()
            return .skipped
        }
        transcriptStorage += delta
        if let reason = latchStorage {
            lock.unlock()
            return .latched(reason)
        }
        lock.unlock()

        if let reason = blockingReason() {
            return latched(reason)
        }
        guard sink.emit(delta) else {
            return latched(.insertFailed)
        }

        lock.lock()
        defer { lock.unlock() }
        guard active, !finished else { return .skipped }
        typedStorage += delta
        return .typed(delta)
    }

    func finish(tail: String, generation token: Int) -> FinalOutcome {
        lock.lock()
        guard active, token == generation else {
            lock.unlock()
            return .nothing
        }
        guard !finished else {
            lock.unlock()
            return .duplicate
        }
        finished = true
        if !tail.isEmpty { transcriptStorage += tail }
        let reason = latchStorage
        let pendingTail = tail
        let full = transcriptStorage
        let typed = typedStorage
        lock.unlock()

        if let reason {
            let remainder = DictationSession.remainder(full: full, typed: typed)
            return remainder.isEmpty ? .nothing : .clipboard(text: remainder, reason: reason)
        }
        guard !pendingTail.isEmpty else {
            return typed.isEmpty ? .nothing : .typed("")
        }

        if let blocked = blockingReason() {
            lock.lock()
            latchStorage = blocked
            lock.unlock()
            return .clipboard(text: DictationSession.remainder(full: full, typed: typed), reason: blocked)
        }
        guard sink.emit(pendingTail) else {
            lock.lock()
            latchStorage = .insertFailed
            lock.unlock()
            return .clipboard(
                text: DictationSession.remainder(full: full, typed: typed),
                reason: .insertFailed
            )
        }
        lock.lock()
        typedStorage += pendingTail
        lock.unlock()
        return .typed(pendingTail)
    }

    func cancel() {
        lock.lock()
        active = false
        finished = true
        lock.unlock()
        gate.release()
    }

    private func blockingReason() -> LatchReason? {
        guard gate.isAvailable else { return .unavailable }
        guard !gate.isSecure else { return .secure }
        guard gate.stillFocused() else { return .focusLost }
        return nil
    }

    private func latched(_ reason: LatchReason) -> InjectionOutcome {
        lock.lock()
        if latchStorage == nil { latchStorage = reason }
        let stored = latchStorage ?? reason
        lock.unlock()
        return .latched(stored)
    }

    static func remainder(full: String, typed: String) -> String {
        guard !typed.isEmpty else { return full }
        guard full.hasPrefix(typed) else { return full }
        return String(full.dropFirst(typed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
