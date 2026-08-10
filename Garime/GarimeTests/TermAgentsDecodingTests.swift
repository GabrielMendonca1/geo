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
    }

    func testAllEmptyProjectsHideLabels() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"pi","status":"idle"},
          {"host":"vm","agent":"claude","status":"working"}]}
        """)
        let groups = TermAgentOrder.grouped(payload.agents)
        XCTAssertEqual(groups.map(\.project), [""])
    }

    func testIdIsStableWhenTitleAndStatusChange() throws {
        let before = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","title":"a","project":"garime","pane":"w1:p3"}]}
        """)
        let after = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"working","title":"b","project":"garime","pane":"w1:p3"}]}
        """)
        XCTAssertEqual(before.agents.first?.id, after.agents.first?.id)
    }

    func testIdFallsBackToTitleWhenPaneIsEmpty() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"pi","status":"running","title":"curador","project":""}]}
        """)
        XCTAssertEqual(payload.agents.first?.id, "vm||pi|curador")
    }

    func testGroupLevelTakesTheMostActiveAgent() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"a"},
          {"host":"mac","agent":"codex","status":"working","project":"a"},
          {"host":"mac","agent":"kimi","status":"idle","project":"b"},
          {"host":"mac","agent":"pi","status":"unknown","project":"c"}]}
        """)
        let groups = TermAgentOrder.grouped(payload.agents)
        XCTAssertEqual(groups.map(\.level), [.working, .idle, .dormant])
        XCTAssertEqual(groups.map(\.hasBusy), [true, false, false])
    }

    func testRankedPutsBusyFirstThenAlphabeticalAndEmptyLast() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"vm","agent":"pi","status":"running","project":""},
          {"host":"mac","agent":"claude","status":"idle","project":"alfa"},
          {"host":"mac","agent":"codex","status":"idle","project":"beta"},
          {"host":"mac","agent":"kimi","status":"working","project":"zulu"}]}
        """)
        let ranked = TermAgentOrder.ranked(TermAgentOrder.grouped(payload.agents))
        XCTAssertEqual(ranked.map(\.project), ["zulu", "alfa", "beta", ""])
    }

    func testAutoExpandedHoldsBusyProjectsPlusTheEmptyOne() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"working","project":"alfa"},
          {"host":"mac","agent":"codex","status":"idle","project":"beta"},
          {"host":"vm","agent":"pi","status":"unknown","project":""}]}
        """)
        let open = TermAgentOrder.autoExpanded(TermAgentOrder.grouped(payload.agents))
        XCTAssertEqual(open, ["alfa", ""])
    }

    func testMergedKeepsFrozenOrderWhenOnlyStatusChanges() throws {
        let first = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"working","project":"alfa","pane":"w1:p1"},
          {"host":"mac","agent":"codex","status":"idle","project":"beta","pane":"w1:p2"}]}
        """)
        let layout = TermAgentOrder.ranked(TermAgentOrder.grouped(first.agents))
        let second = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"codex","status":"working","project":"beta","pane":"w1:p2"},
          {"host":"mac","agent":"claude","status":"idle","project":"alfa","pane":"w1:p1"}]}
        """)
        let merged = TermAgentOrder.merged(layout: layout, live: TermAgentOrder.sorted(second.agents))
        XCTAssertEqual(merged.map(\.project), ["alfa", "beta"])
        XCTAssertEqual(merged.first?.agents.first?.status, "idle")
        XCTAssertEqual(merged.last?.agents.first?.status, "working")
    }

    func testMergedAppendsNewAgentAndNewProjectAtTheEnd() throws {
        let first = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"alfa","pane":"w1:p1"}]}
        """)
        let layout = TermAgentOrder.grouped(first.agents)
        let second = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"kimi","status":"working","project":"zulu","pane":"w2:p1"},
          {"host":"mac","agent":"codex","status":"working","project":"alfa","pane":"w1:p9"},
          {"host":"mac","agent":"claude","status":"idle","project":"alfa","pane":"w1:p1"}]}
        """)
        let merged = TermAgentOrder.merged(layout: layout, live: second.agents)
        XCTAssertEqual(merged.map(\.project), ["alfa", "zulu"])
        XCTAssertEqual(merged.first?.agents.map(\.agent), ["claude", "codex"])
    }

    func testMergedDropsVanishedAgentsAndEmptyGroups() throws {
        let first = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"alfa","pane":"w1:p1"},
          {"host":"mac","agent":"codex","status":"idle","project":"beta","pane":"w1:p2"}]}
        """)
        let layout = TermAgentOrder.grouped(first.agents)
        let second = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"codex","status":"idle","project":"beta","pane":"w1:p2"}]}
        """)
        let merged = TermAgentOrder.merged(layout: layout, live: second.agents)
        XCTAssertEqual(merged.map(\.project), ["beta"])
    }

    func testAdoptingReturnsOnlyProjectsMissingFromTheFrozenLayout() throws {
        let first = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"alfa","pane":"w1:p1"}]}
        """)
        let layout = TermAgentOrder.grouped(first.agents)
        let second = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"alfa","pane":"w1:p1"},
          {"host":"mac","agent":"codex","status":"idle","project":"alfa","pane":"w1:p9"},
          {"host":"mac","agent":"kimi","status":"idle","project":"zulu","pane":"w2:p1"}]}
        """)
        let fresh = TermAgentOrder.adopting(layout: layout, live: second.agents)
        XCTAssertEqual(fresh.map(\.project), ["zulu"])
        XCTAssertTrue(TermAgentOrder.adopting(layout: layout + fresh, live: second.agents).isEmpty)
    }

    func testPlaceIsTheCwdBasenameUnlessItRepeatsTheProject() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"garime","cwd":"/Users/biel/Garime/spirit","pane":"w1:p1"},
          {"host":"mac","agent":"claude","status":"idle","project":"garime","cwd":"/Users/biel/garime","pane":"w1:p2"},
          {"host":"vm","agent":"pi","status":"running","project":"","cwd":"","pane":""}]}
        """)
        XCTAssertEqual(payload.agents.map(\.place), ["spirit", "", ""])
    }

    func testMarksCapAtFiveWithOverflow() throws {
        let payload = try decode("""
        {"units":[],"mac_online":true,"agents":[
          {"host":"mac","agent":"claude","status":"idle","project":"a","pane":"w1:p1"},
          {"host":"mac","agent":"codex","status":"idle","project":"a","pane":"w1:p2"},
          {"host":"mac","agent":"opencode","status":"idle","project":"a","pane":"w1:p3"},
          {"host":"mac","agent":"kimi","status":"idle","project":"a","pane":"w1:p4"},
          {"host":"mac","agent":"pi","status":"idle","project":"a","pane":"w1:p5"},
          {"host":"mac","agent":"aider","status":"idle","project":"a","pane":"w1:p6"},
          {"host":"mac","agent":"claude","status":"idle","project":"a","pane":"w1:p7"}]}
        """)
        let group = try XCTUnwrap(TermAgentOrder.grouped(payload.agents).first)
        XCTAssertEqual(group.marks.overflow, 2)
        XCTAssertEqual(
            group.marks.symbols,
            ["A", "asterisk", "asterisk", "chevron.left.forwardslash.chevron.right", "moon"]
        )
    }
}
