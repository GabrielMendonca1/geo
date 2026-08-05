import XCTest
@testable import Garime

final class StatusIndicatorTests: XCTestCase {
    func testAgentStatusMapping() {
        XCTAssertEqual(StatusLevel.agent(status: "working"), .working)
        XCTAssertEqual(StatusLevel.agent(status: "running"), .working)
        XCTAssertEqual(StatusLevel.agent(status: "idle"), .idle)
        XCTAssertEqual(StatusLevel.agent(status: "unknown"), .dormant)
        XCTAssertEqual(StatusLevel.agent(status: ""), .dormant)
    }

    func testLiveAndLinkMapping() {
        XCTAssertEqual(StatusLevel.live(true), .healthy)
        XCTAssertEqual(StatusLevel.live(false), .dormant)
        XCTAssertEqual(StatusLevel.link(true), .healthy)
        XCTAssertEqual(StatusLevel.link(false), .failed)
    }

    func testFillIsASecondChannelBesidesColor() {
        XCTAssertTrue(StatusLevel.working.isFilled)
        XCTAssertTrue(StatusLevel.healthy.isFilled)
        XCTAssertTrue(StatusLevel.idle.isFilled)
        XCTAssertFalse(StatusLevel.dormant.isFilled)
        XCTAssertFalse(StatusLevel.failed.isFilled)
    }

    func testServiceCheckOutcomeMapping() {
        XCTAssertEqual(ServiceCheck(id: "a", name: "a", outcome: .ok).level, .healthy)
        XCTAssertEqual(ServiceCheck(id: "a", name: "a", outcome: .failed).level, .failed)
        XCTAssertEqual(ServiceCheck(id: "a", name: "a", outcome: .running).level, .working)
        XCTAssertEqual(ServiceCheck(id: "a", name: "a", outcome: .pending).level, .dormant)
        XCTAssertEqual(ServiceCheck(id: "a", name: "a", outcome: .unavailable).level, .dormant)
    }

    func testAgentMarks() {
        XCTAssertEqual(AgentMark.symbol(for: "claude"), "asterisk")
        XCTAssertEqual(AgentMark.symbol(for: "Codex"), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(AgentMark.symbol(for: "opencode"), "curlybraces")
        XCTAssertEqual(AgentMark.symbol(for: "kimi"), "moon")
        XCTAssertNil(AgentMark.symbol(for: "pi"))
    }

    func testAgentGlyphFallback() {
        XCTAssertEqual(AgentMark.glyph(for: "pi"), "π")
        XCTAssertEqual(AgentMark.glyph(for: "aider"), "A")
        XCTAssertEqual(AgentMark.glyph(for: ""), "?")
    }
}
