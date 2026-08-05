import XCTest
@testable import Garime

final class TermAgentsDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> TermAgentsPayload {
        try JSONDecoder().decode(TermAgentsPayload.self, from: Data(json.utf8))
    }

    func testLegacyPayloadWithoutAgentsKeyStillDecodes() throws {
        let payload = try decode("""
        {"units":[{"name":"garime-wa","active":true,"since":"Tue 2026-08-04 10:36:49 -03"}],"mac_online":true}
        """)
        XCTAssertEqual(payload.units.count, 1)
        XCTAssertTrue(payload.macOnline)
        XCTAssertTrue(payload.agents.isEmpty)
    }

    func testFullAgentDecodes() throws {
        let payload = try decode("""
        {"units":[],"mac_online":false,"agents":[
          {"host":"mac","agent":"claude","status":"idle","title":"tech stack audit",
           "project":"garime","cwd":"/Users/biel/Garime"}]}
        """)
        let agent = try XCTUnwrap(payload.agents.first)
        XCTAssertEqual(agent.host, "mac")
        XCTAssertEqual(agent.agent, "claude")
        XCTAssertEqual(agent.title, "tech stack audit")
        XCTAssertEqual(agent.project, "garime")
        XCTAssertTrue(agent.isIdle)
        XCTAssertFalse(agent.isBusy)
    }

    func testMacAgentWithPaneIsAttachable() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"working","project":"garime","pane":"w1:p3"}]}
        """)
        let agent = try XCTUnwrap(payload.agents.first)
        XCTAssertEqual(agent.pane, "w1:p3")
        XCTAssertTrue(agent.isAttachable)
    }

    func testVMAgentWithoutPaneIsNotAttachable() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"pi","status":"working","project":"garime"}]}
        """)
        let agent = try XCTUnwrap(payload.agents.first)
        XCTAssertEqual(agent.pane, "")
        XCTAssertFalse(agent.isAttachable)
    }

    func testMacAgentWithoutProjectIsNotAttachable() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","pane":"w0:p1"}]}
        """)
        let agent = try XCTUnwrap(payload.agents.first)
        XCTAssertFalse(agent.isAttachable)
    }

    func testMissingAndNullFieldsBecomeEmptyStrings() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[{"host":"vm","agent":"pi","status":"running","title":null}]}
        """)
        let agent = try XCTUnwrap(payload.agents.first)
        XCTAssertEqual(agent.title, "")
        XCTAssertEqual(agent.project, "")
        XCTAssertEqual(agent.cwd, "")
        XCTAssertTrue(agent.isBusy)
    }

    func testAgentWithoutNameIsDropped() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[{"host":"mac","status":"unknown"}]}
        """)
        XCTAssertTrue(payload.agents.isEmpty)
    }

    func testGarbageAgentsValueDoesNotBreakUnits() throws {
        let payload = try decode("""
        {"units":[{"name":"syncthing-garime","active":false,"since":""}],"mac_online":true,"agents":"nope"}
        """)
        XCTAssertEqual(payload.units.first?.name, "syncthing-garime")
        XCTAssertTrue(payload.agents.isEmpty)
    }

    func testOrderGroupsByProjectAndPutsWorkingFirst() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"kimi","status":"idle","project":"omni"},
          {"host":"vm","agent":"pi","status":"unknown","project":"garime"},
          {"host":"vm","agent":"claude","status":"running","project":""},
          {"host":"mac","agent":"codex","status":"working","project":"omni"},
          {"host":"mac","agent":"claude","status":"working","project":"garime"}]}
        """)
        let ordered = TermAgentOrder.sorted(payload.agents)
        XCTAssertEqual(ordered.map(\.agent), ["claude", "pi", "codex", "kimi", "claude"])
        XCTAssertEqual(ordered.map(\.project), ["garime", "garime", "omni", "omni", ""])
    }

    func testGroupedSplitsByProjectAndKeepsEmptyProjectLast() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"kimi","status":"idle","project":"omni"},
          {"host":"vm","agent":"claude","status":"running","project":""},
          {"host":"mac","agent":"claude","status":"working","project":"garime"}]}
        """)
        let groups = TermAgentOrder.grouped(payload.agents)
        XCTAssertEqual(groups.map(\.project), ["garime", "omni", ""])
        XCTAssertEqual(groups.map { $0.agents.count }, [1, 1, 1])
        XCTAssertEqual(groups.last?.label, "sem projeto")
        XCTAssertTrue(TermAgentOrder.showsProjectLabels(groups))
    }

    func testSingleProjectShowsLabels() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"garime"},
          {"host":"mac","agent":"pi","status":"working","project":"garime"}]}
        """)
        let groups = TermAgentOrder.grouped(payload.agents)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.agents.count, 2)
        XCTAssertTrue(TermAgentOrder.showsProjectLabels(groups))
    }

    func testAllEmptyProjectsHideLabels() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"pi","status":"idle"},
          {"host":"vm","agent":"claude","status":"working"}]}
        """)
        let groups = TermAgentOrder.grouped(payload.agents)
        XCTAssertEqual(groups.map(\.project), [""])
        XCTAssertFalse(TermAgentOrder.showsProjectLabels(groups))
    }
}
