import Foundation
import CryptoKit
import os

final class MCPAuthGuard: @unchecked Sendable {
    struct ValidatedEndpoint: Sendable, Equatable {
        let endpointId: UUID
        let endpointName: String
    }

    struct TokenEntry: Sendable {
        let endpoint: ValidatedEndpoint
        let expiresAt: Date
    }

    struct RateState: Sendable {
        var failureTimestamps: [Date]
        var blockedUntil: Date?
    }

    private struct State: Sendable {
        var tokens: [String: TokenEntry] = [:]
        var rateLimits: [String: RateState] = [:]
    }

    static let tokenTTL: TimeInterval = 86400
    static let failureWindow: TimeInterval = 60
    static let maxFailuresPerWindow: Int = 5
    static let blockDuration: TimeInterval = 60

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    static func digest(of token: String) -> String {
        let hash = SHA256.hash(data: Data(token.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func register(token: String, endpointId: UUID, endpointName: String) {
        let endpoint = ValidatedEndpoint(endpointId: endpointId, endpointName: endpointName)
        let key = Self.digest(of: token)
        let entry = TokenEntry(endpoint: endpoint, expiresAt: Date().addingTimeInterval(Self.tokenTTL))
        state.withLock { state in
            state.tokens[key] = entry
        }
    }

    func revoke(token: String) {
        let key = Self.digest(of: token)
        state.withLock { state in
            _ = state.tokens.removeValue(forKey: key)
        }
    }

    func revokeDigest(_ digest: String) {
        state.withLock { state in
            _ = state.tokens.removeValue(forKey: digest)
        }
    }

    func revokeAll(for endpointId: UUID) {
        state.withLock { state in
            state.tokens = state.tokens.filter { $0.value.endpoint.endpointId != endpointId }
        }
    }

    func validate(token: String) -> ValidatedEndpoint? {
        return validate(token: token, clientId: nil)
    }

    func validate(token: String, clientId: String?) -> ValidatedEndpoint? {
        let now = Date()
        let rateKey = clientId ?? "anonymous"
        let incoming = Self.digest(of: token)

        return state.withLock { state in
            if var rateState = state.rateLimits[rateKey], let blockedUntil = rateState.blockedUntil {
                if now < blockedUntil {
                    return nil
                } else {
                    rateState.blockedUntil = nil
                    rateState.failureTimestamps.removeAll()
                    state.rateLimits[rateKey] = rateState
                }
            }

            var matched: (String, TokenEntry)?
            for (storedDigest, entry) in state.tokens {
                if Self.constantTimeEquals(incoming, storedDigest) {
                    matched = (storedDigest, entry)
                }
            }

            if let (storedDigest, entry) = matched {
                if entry.expiresAt <= now {
                    state.tokens.removeValue(forKey: storedDigest)
                    Self.recordFailure(key: rateKey, now: now, state: &state)
                    return nil
                }
                state.rateLimits.removeValue(forKey: rateKey)
                return entry.endpoint
            }

            Self.recordFailure(key: rateKey, now: now, state: &state)
            return nil
        }
    }

    func snapshot() -> [String: ValidatedEndpoint] {
        state.withLock { state in
            var result: [String: ValidatedEndpoint] = [:]
            for (digest, entry) in state.tokens {
                result[digest] = entry.endpoint
            }
            return result
        }
    }

    func isRegistered(token: String) -> Bool {
        let key = Self.digest(of: token)
        return state.withLock { state in
            state.tokens[key] != nil
        }
    }

    private static func recordFailure(key: String, now: Date, state: inout State) {
        var rateState = state.rateLimits[key] ?? RateState(failureTimestamps: [], blockedUntil: nil)
        let cutoff = now.addingTimeInterval(-Self.failureWindow)
        rateState.failureTimestamps = rateState.failureTimestamps.filter { $0 > cutoff }
        rateState.failureTimestamps.append(now)
        if rateState.failureTimestamps.count >= Self.maxFailuresPerWindow {
            rateState.blockedUntil = now.addingTimeInterval(Self.blockDuration)
        }
        state.rateLimits[key] = rateState
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}
