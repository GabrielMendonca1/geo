import XCTest
@testable import Geo

@MainActor
final class NanoCardTests: XCTestCase {
    func testQuarantinedRemovedNanoCardSurface() throws {
        throw XCTSkip("Quarantined: NanoToolCall / NanoNativeCardKind / AgentDispatchCard / NanoBlockCardView / TagPill were removed when the in-app Nano chat-card surface was deleted (Nano is now dashboard-only). No current API to test against.")
    }
}
