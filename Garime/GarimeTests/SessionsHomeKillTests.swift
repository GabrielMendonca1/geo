import XCTest
@testable import Garime

final class SessionsHomeKillTests: XCTestCase {
    private func process(_ json: String) throws -> TermAgentProcess {
        try JSONDecoder().decode(TermAgentProcess.self, from: Data(json.utf8))
    }

    func testMacSessionIsNotKillable() {
        XCTAssertFalse(SessionsHomeKill.killable(session: TerminalSessionList.mac))
        XCTAssertFalse(SessionsHomeKill.killable(session: TerminalSessionList.reserved))
        XCTAssertFalse(SessionsHomeKill.killable(session: "mac:qualquer"))
    }

    func testVMSessionIsKillable() {
        XCTAssertTrue(SessionsHomeKill.killable(session: "vm:mobile"))
        XCTAssertTrue(SessionsHomeKill.killable(session: "vm:claude"))
    }

    func testSessionAgentIsKillable() throws {
        let agent = try process(#"""
        {"host":"vm","agent":"claude","status":"working","project":"garime","session":"claude"}
        """#)
        XCTAssertEqual(agent.chatRef, .session("claude"))
        XCTAssertEqual(SessionsHomeKill.target(agent), "vm:claude")
    }

    func testPaneAgentIsNotKillable() throws {
        let agent = try process(#"""
        {"host":"mac","agent":"herdr","status":"idle","project":"garime","pane":"w1:p1"}
        """#)
        XCTAssertEqual(agent.chatRef, .pane(project: "garime", pane: "w1:p1"))
        XCTAssertNil(SessionsHomeKill.target(agent))
    }

    func testAgentWithoutTargetIsNotKillable() throws {
        let agent = try process(#"""
        {"host":"vm","agent":"pi","status":"idle","project":"garime"}
        """#)
        XCTAssertNil(SessionsHomeKill.target(agent))
    }

    func testPromotedSessionIsNotListedTwice() throws {
        let agent = try process(#"""
        {"host":"vm","agent":"claude","status":"working","project":"garime","session":"claude"}
        """#)
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile", "vm:claude", "mac:mac"], agents: [agent]),
            ["vm:mobile", "mac:mac"]
        )
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile", "vm:claude", "mac:mac"], agents: []),
            ["vm:mobile", "vm:claude", "mac:mac"]
        )
    }
}
