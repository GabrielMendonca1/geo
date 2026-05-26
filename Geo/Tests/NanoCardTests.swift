import XCTest
@testable import Geo

@MainActor
final class NanoCardTests: XCTestCase {

    private func makeCall(
        name: String,
        input: JSONValue = .object([:]),
        result: JSONValue? = nil,
        partialResult: JSONValue? = nil,
        isError: Bool = false
    ) -> NanoToolCall {
        NanoToolCall(
            id: "call-\(UUID().uuidString.prefix(6))",
            name: name,
            input: input,
            result: result,
            partialResult: partialResult,
            isError: isError
        )
    }

    func testTagPillRendersTagNameAndColor() {
        let color = TagColor(red: 0.0, green: 0.33, blue: 1.0)
        let tag = Tag(id: "tag-1", name: "research", color: color)
        let pill = TagPill(tag: tag)
        XCTAssertEqual(pill.tag.id, "tag-1")
        XCTAssertEqual(pill.tag.name, "research")
        XCTAssertEqual(pill.tag.color, color)
    }

    func testNanoNativeCardKindListTagsParsesArray() {
        let result: JSONValue = .array([
            .object(["id": .string("t1"), "name": .string("focus")]),
            .object(["id": .string("t2"), "name": .string("idea")])
        ])
        let call = makeCall(name: "mcp_geo_list_tags", result: result)
        guard case .tag(let tags) = NanoNativeCardKind.from(call: call) else {
            return XCTFail("Expected .tag kind")
        }
        XCTAssertEqual(tags.map { $0.id }, ["t1", "t2"])
        XCTAssertEqual(tags.map { $0.name }, ["focus", "idea"])
    }

    func testNanoNativeCardKindSetBlockTagParsesSingleTag() {
        let result: JSONValue = .object([
            "id": .string("tg-7"),
            "name": .string("ship-it"),
            "color": .object(["red": .double(0.1), "green": .double(0.2), "blue": .double(0.9)])
        ])
        let call = makeCall(name: "set_block_tag", result: result)
        guard case .tag(let tags) = NanoNativeCardKind.from(call: call),
              let first = tags.first else {
            return XCTFail("Expected single tag")
        }
        XCTAssertEqual(first.id, "tg-7")
        XCTAssertEqual(first.name, "ship-it")
        XCTAssertEqual(first.color.blue, 0.9, accuracy: 0.0001)
    }

    func testAgentDispatchCardQueuedWhenNoPartialOrResult() {
        let call = makeCall(name: "mcp_hermes_dispatch_subagent", input: .object(["prompt": .string("audit nano cards")]))
        let card = AgentDispatchCard(call: call)
        XCTAssertNil(card.call.result)
        XCTAssertNil(card.call.partialResult)
        XCTAssertEqual(card.call.status, .running)
    }

    func testAgentDispatchCardRunningWithPartialTail() {
        let partial: JSONValue = .object([
            "workspace_path": .string("/tmp/ws/abc"),
            "tail": .array([.string("step 1"), .string("step 2"), .string("step 3")])
        ])
        let call = makeCall(
            name: "mcp_hermes_dispatch_subagent",
            input: .object(["prompt": .string("run tests")]),
            partialResult: partial
        )
        let card = AgentDispatchCard(call: call)
        XCTAssertNotNil(card.call.partialResult)
        XCTAssertNil(card.call.result)
    }

    func testNanoCardKindDispatchesHermesSubagent() {
        let call = makeCall(name: "mcp_hermes_dispatch_subagent", input: .object(["prompt": .string("x")]))
        guard case .agentDispatch = NanoNativeCardKind.from(call: call) else {
            return XCTFail("Expected .agentDispatch")
        }
    }

    func testNanoCardKindDispatchesLegacyAiDispatchAgent() {
        let call = makeCall(name: "ai_dispatch_agent", input: .object(["prompt": .string("x")]))
        guard case .agentDispatch = NanoNativeCardKind.from(call: call) else {
            return XCTFail("Expected .agentDispatch for legacy name")
        }
    }

    func testBlockCardOnTapClosureInvoked() {
        var fired = false
        let card = NanoBlockCardView(blockId: "blk-42", onTap: { fired = true })
        card.onTap?()
        XCTAssertTrue(fired)
        XCTAssertEqual(card.blockId, "blk-42")
    }

    func testNanoToolCallPartialResultRoundTripsThroughEquality() {
        let a = NanoToolCall(
            id: "x",
            name: "n",
            input: .object([:]),
            partialResult: .object(["tail": .array([.string("hi")])])
        )
        let b = a
        XCTAssertEqual(a, b)
    }
}
