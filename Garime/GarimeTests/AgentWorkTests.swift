import XCTest
@testable import Garime

final class AgentWorkTests: XCTestCase {
    private func decode(_ json: String) throws -> AgentWorkPayload {
        try JSONDecoder().decode(AgentWorkPayload.self, from: Data(json.utf8))
    }

    func testDecodesLivePayload() throws {
        let payload = try decode(#"""
        {"agent":"claude","supported":true,"resolved":"reported",
         "workflows":[{"id":"wf_12ec19ba-56f","running":2,"done":6,"since":"2026-08-05T13:22:31Z"}],
         "subagents":[{"id":"a1b5a89ea","type":"worker","running":true,"since":"2026-08-05T13:40:02Z"}],
         "truncated":false}
        """#)

        XCTAssertEqual(payload.agent, "claude")
        XCTAssertTrue(payload.supported)
        XCTAssertEqual(payload.workflows.count, 1)
        XCTAssertEqual(payload.workflows[0].total, 8)
        XCTAssertEqual(payload.subagents.count, 1)
        XCTAssertFalse(payload.truncated)
        XCTAssertTrue(payload.hasWork)
        XCTAssertEqual(payload.runningAgents, 3)
        XCTAssertEqual(payload.summary, "1 workflow · 3 agentes")
    }

    func testUnsupportedAgentHasNoWork() throws {
        let payload = try decode(#"{"agent":"pi","supported":false,"resolved":"","truncated":false}"#)

        XCTAssertFalse(payload.supported)
        XCTAssertFalse(payload.hasWork)
        XCTAssertTrue(payload.liveWorkflows.isEmpty)
        XCTAssertTrue(payload.liveSubagents.isEmpty)
        XCTAssertEqual(payload.runningAgents, 0)
    }

    func testUnsupportedAgentWithStaleListsStillHasNoWork() throws {
        let payload = try decode(#"""
        {"agent":"pi","supported":false,
         "workflows":[{"id":"wf_a","running":3,"done":0,"since":""}],
         "subagents":[{"id":"s1","type":"worker","running":true,"since":""}]}
        """#)

        XCTAssertFalse(payload.hasWork)
        XCTAssertEqual(payload.runningAgents, 0)
    }

    func testMissingListsAndFieldsDecodeToEmpty() throws {
        let payload = try decode(#"{"agent":"claude"}"#)

        XCTAssertTrue(payload.supported)
        XCTAssertTrue(payload.workflows.isEmpty)
        XCTAssertTrue(payload.subagents.isEmpty)
        XCTAssertFalse(payload.truncated)
        XCTAssertFalse(payload.hasWork)
    }

    func testTruncatedFlagDecodes() throws {
        let payload = try decode(#"{"agent":"claude","supported":true,"workflows":[],"subagents":[],"truncated":true}"#)

        XCTAssertTrue(payload.truncated)
        XCTAssertFalse(payload.hasWork)
    }

    func testFallbackResolutionIsNotAnError() throws {
        let payload = try decode(#"""
        {"agent":"claude","supported":true,"resolved":"fallback",
         "workflows":[{"id":"wf_a","running":1,"done":0,"since":""}],"subagents":[]}
        """#)

        XCTAssertTrue(payload.hasWork)
        XCTAssertEqual(payload.runningAgents, 1)
    }

    func testFinishedWorkflowsAreNotWork() throws {
        let payload = try decode(#"""
        {"agent":"claude","supported":true,
         "workflows":[{"id":"wf_a","running":0,"done":8,"since":""}],
         "subagents":[{"id":"s1","type":"worker","running":false,"since":""}]}
        """#)

        XCTAssertFalse(payload.hasWork)
        XCTAssertEqual(payload.runningAgents, 0)
    }

    func testEntriesWithoutIDAreDropped() throws {
        let payload = try decode(#"""
        {"agent":"claude","supported":true,
         "workflows":[{"running":2,"done":1},{"id":"wf_a","running":1,"done":1}],
         "subagents":[{"type":"worker","running":true}]}
        """#)

        XCTAssertEqual(payload.workflows.count, 1)
        XCTAssertTrue(payload.subagents.isEmpty)
        XCTAssertEqual(payload.runningAgents, 1)
    }

    func testSummaryCountsSubagentsWithoutWorkflows() throws {
        let payload = try decode(#"""
        {"agent":"claude","supported":true,"workflows":[],
         "subagents":[{"id":"s1","type":"worker","running":true,"since":""}]}
        """#)

        XCTAssertTrue(payload.hasWork)
        XCTAssertEqual(payload.summary, "1 agente")
    }

    func testSummaryPluralizesWorkflowsAndAgents() throws {
        let payload = try decode(#"""
        {"agent":"claude","supported":true,
         "workflows":[{"id":"a","running":2,"done":0,"since":""},{"id":"b","running":2,"done":3,"since":""}],
         "subagents":[{"id":"s1","type":"worker","running":true,"since":""}]}
        """#)

        XCTAssertEqual(payload.summary, "2 workflows · 5 agentes")
    }

    func testNoneIsEmpty() {
        XCTAssertFalse(AgentWorkPayload.none.hasWork)
        XCTAssertEqual(AgentWorkPayload.none.runningAgents, 0)
    }

    func testRelativeTimeIsShortPortuguese() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func since(_ seconds: TimeInterval) -> String {
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-seconds))
            return AgentWorkClock.short(stamp, now: now)
        }

        XCTAssertEqual(since(5), "agora")
        XCTAssertEqual(since(59), "agora")
        XCTAssertEqual(since(120), "2 min")
        XCTAssertEqual(since(59 * 60), "59 min")
        XCTAssertEqual(since(3600), "1 h")
        XCTAssertEqual(since(5 * 3600), "5 h")
        XCTAssertEqual(since(50 * 3600), "2 d")
        XCTAssertEqual(AgentWorkClock.short("", now: now), "")
        XCTAssertEqual(AgentWorkClock.short("nonsense", now: now), "")
    }

    func testEndpointPath() {
        XCTAssertEqual(
            BridgeEndpoint.termAgentWork(target: .pane(project: "garime", pane: "w1:p3")).path,
            "/term/agent-work?project=garime&pane=w1%3Ap3"
        )
    }
}
