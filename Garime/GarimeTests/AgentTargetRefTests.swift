import XCTest
@testable import Garime

final class AgentTargetRefEndpointTests: XCTestCase {
    func testChatPathForBothAddressingForms() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: .pane(project: "garime", pane: "w1:p3"), limit: 80).path,
            "/term/agent-chat?project=garime&pane=w1%3Ap3&limit=80"
        )
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: .session("claude"), limit: 80).path,
            "/term/agent-chat?session=claude&limit=80"
        )
    }

    func testWorkPathForBothAddressingForms() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentWork(target: .pane(project: "garime", pane: "w1:p3")).path,
            "/term/agent-work?project=garime&pane=w1%3Ap3"
        )
        XCTAssertEqual(
            BridgeEndpoint.termAgentWork(target: .session("pi")).path,
            "/term/agent-work?session=pi"
        )
    }

    func testPromptPathForBothAddressingForms() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentPrompt(target: .pane(project: "meu projeto", pane: "w1:p3")).path,
            "/term/agent-prompt?project=meu%20projeto&pane=w1%3Ap3"
        )
        XCTAssertEqual(
            BridgeEndpoint.termAgentPrompt(target: .session("sessão 2")).path,
            "/term/agent-prompt?session=sess%C3%A3o%202"
        )
    }

    func testSessionSelectorNeverCarriesProjectOrPane() {
        let path = BridgeEndpoint.termAgentChat(target: .session("claude"), limit: 10).path
        XCTAssertFalse(path.contains("project="))
        XCTAssertFalse(path.contains("pane="))
    }

    func testChatPathClampsLimitOnSessionForm() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: .session("claude"), limit: 0).path,
            "/term/agent-chat?session=claude&limit=1"
        )
        XCTAssertEqual(
            BridgeEndpoint.termAgentChat(target: .session("claude"), limit: 900).path,
            "/term/agent-chat?session=claude&limit=200"
        )
    }
}

final class AgentRowTouchTests: XCTestCase {
    private func agents(_ json: String) throws -> [TermAgentProcess] {
        try JSONDecoder().decode(TermAgentsPayload.self, from: Data(json.utf8)).agents
    }

    func testVMAgentWithSessionIsTouchable() throws {
        let agent = try XCTUnwrap(agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"claude","status":"working","session":"claude"}]}
        """).first)
        XCTAssertTrue(agent.isChattable)
        XCTAssertEqual(agent.chatRef, .session("claude"))
        XCTAssertFalse(agent.isAttachable)
        XCTAssertNotNil(AgentChatTarget(agent))
    }

    func testVMAgentWithoutSessionIsNotTouchable() throws {
        let agent = try XCTUnwrap(agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"pi","status":"working","project":"garime"}]}
        """).first)
        XCTAssertFalse(agent.isChattable)
        XCTAssertNil(agent.chatRef)
        XCTAssertNil(AgentChatTarget(agent))
    }

    func testMacAgentWithPaneIsTouchable() throws {
        let agent = try XCTUnwrap(agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"garime","pane":"w1:p3"}]}
        """).first)
        XCTAssertTrue(agent.isChattable)
        XCTAssertEqual(agent.chatRef, .pane(project: "garime", pane: "w1:p3"))
        XCTAssertNotNil(AgentChatTarget(agent))
    }

    func testMacAgentWithSessionButNoPaneIsNotTouchable() throws {
        let agent = try XCTUnwrap(agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"garime","session":"claude"}]}
        """).first)
        XCTAssertFalse(agent.isChattable)
        XCTAssertNil(AgentChatTarget(agent))
    }

    func testTwoVMSessionsOfTheSameAgentKeepDistinctIDs() throws {
        let list = try agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"claude","status":"idle","session":"a"},
          {"host":"vm","agent":"claude","status":"idle","session":"b"}]}
        """)
        XCTAssertEqual(Set(list.map(\.id)).count, 2)
    }

    func testTargetFromVMAgentFallsBackToSessionSubtitleFields() throws {
        let agent = try XCTUnwrap(agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"claude","status":"working","session":"claude","title":"curador"}]}
        """).first)
        let target = try XCTUnwrap(AgentChatTarget(agent))
        XCTAssertEqual(target.ref, .session("claude"))
        XCTAssertEqual(target.agent, "claude")
        XCTAssertEqual(target.status, "working")
        XCTAssertEqual(target.title, "curador")
    }
}

final class SessionsHomeDisplayTests: XCTestCase {
    private func agents(_ json: String) throws -> [TermAgentProcess] {
        try JSONDecoder().decode(TermAgentsPayload.self, from: Data(json.utf8)).agents
    }

    func testSessionThatBecameAnAgentStopsBeingACard() throws {
        let live = try agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"claude","status":"working","session":"mobile2"}]}
        """)
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile", "vm:mobile2", "mac:mac"], agents: live),
            ["vm:mobile", "mac:mac"]
        )
    }

    func testMacCardAndSessionlessVMAgentsNeverHideCards() throws {
        let live = try agents("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"garime","pane":"w1:p3","session":"mobile"},
          {"host":"vm","agent":"pi","status":"working"}]}
        """)
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile", "mac:mac"], agents: live),
            ["vm:mobile", "mac:mac"]
        )
    }

    func testCardComesBackWhenTheAgentExits() throws {
        let none: [TermAgentProcess] = []
        XCTAssertEqual(
            SessionsHomeDisplay.rows(["vm:mobile2", "mac:mac"], agents: none),
            ["vm:mobile2", "mac:mac"]
        )
    }
}

final class AgentPromptFailureTests: XCTestCase {
    func testControlCharacterRejectionGetsItsOwnMessage() {
        XCTAssertEqual(
            AgentPromptFailure.text(BridgeError.server(status: 400, code: "invalid_body")),
            "texto com caractere inválido"
        )
        XCTAssertEqual(
            AgentPromptFailure.text(BridgeError.server(status: 404, code: "no_session")),
            "agente sumiu da sessão"
        )
        XCTAssertEqual(
            AgentPromptFailure.text(BridgeError.server(status: 503, code: "unavailable")),
            "host fora do ar"
        )
        XCTAssertEqual(
            AgentPromptFailure.text(BridgeError.unreachable("timeout")),
            "não enviou — toque para tentar de novo"
        )
    }
}
