import XCTest
import SwiftUI
@testable import Geo

final class BlockGraphServiceTests: XCTestCase {

    private func makeEntry(
        id: String,
        title: String,
        content: String,
        tagId: String? = nil,
        tags: [String] = [],
        layer: String = "user"
    ) -> BlockIndexEntry {
        BlockIndexEntry(
            id: id,
            path: "/tmp/\(id).md",
            title: title,
            content: content,
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            tagId: tagId,
            dayId: nil,
            openTaskCount: 0,
            completedTaskCount: 0,
            tags: tags,
            layer: layer
        )
    }

    func testExtractWikiLinksBasic() {
        let result = BlockGraphService.extractWikiLinks(from: "see [[Alpha]] and [[Beta]]")
        XCTAssertEqual(result, ["Alpha", "Beta"])
    }

    func testExtractWikiLinksHandlesPipeAlias() {
        let result = BlockGraphService.extractWikiLinks(from: "[[Page|Display]]")
        XCTAssertEqual(result, ["Page"])
    }

    func testExtractWikiLinksTrimsWhitespace() {
        let result = BlockGraphService.extractWikiLinks(from: "[[  Spaced  ]]")
        XCTAssertEqual(result, ["Spaced"])
    }

    func testExtractWikiLinksIgnoresEmpty() {
        XCTAssertEqual(BlockGraphService.extractWikiLinks(from: "[[]]"), [])
        XCTAssertEqual(BlockGraphService.extractWikiLinks(from: "[[   |alias]]"), [])
    }

    func testExtractWikiLinksMultiplePerLine() {
        let result = BlockGraphService.extractWikiLinks(from: "[[A]] [[B]] [[A]]")
        XCTAssertEqual(result, ["A", "B", "A"])
    }

    func testExtractWikiLinksEmptyContent() {
        XCTAssertEqual(BlockGraphService.extractWikiLinks(from: ""), [])
    }

    func testExtractWikiLinksMalformedBracketsDontMatch() {
        XCTAssertEqual(BlockGraphService.extractWikiLinks(from: "[ [Foo]]"), [])
        XCTAssertEqual(BlockGraphService.extractWikiLinks(from: "[[Foo] ]"), [])
        XCTAssertEqual(BlockGraphService.extractWikiLinks(from: "[[]"), [])
    }

    func testNormalizeLowercasesAndTrims() {
        XCTAssertEqual(BlockGraphService.normalize("  Hello World  "), "hello world")
    }

    func testNormalizeIdempotent() {
        let input = "  Mixed Case  "
        let once = BlockGraphService.normalize(input)
        let twice = BlockGraphService.normalize(once)
        XCTAssertEqual(once, twice)
    }

    func testDeterministicUUIDStable() {
        let a = BlockGraphService.deterministicUUID(from: "block-123")
        let b = BlockGraphService.deterministicUUID(from: "block-123")
        XCTAssertEqual(a, b)
    }

    func testDeterministicUUIDDifferentStringsDiffer() {
        let a = BlockGraphService.deterministicUUID(from: "block-1")
        let b = BlockGraphService.deterministicUUID(from: "block-2")
        XCTAssertNotEqual(a, b)
    }

    func testDeterministicUUIDPassesThroughValidUUIDString() {
        let raw = "11111111-2222-3333-4444-555555555555"
        let parsed = UUID(uuidString: raw)!
        XCTAssertEqual(BlockGraphService.deterministicUUID(from: raw), parsed)
    }

    func testDeterministicUUIDVersionAndVariantBitsSet() {
        let uuid = BlockGraphService.deterministicUUID(from: "needs-synth")
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: uuid.uuid) { raw in
            for i in 0..<16 { bytes[i] = raw[i] }
        }
        XCTAssertEqual(bytes[6] & 0xF0, 0x50)
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)
    }

    func testBuildGraphResolvesEdgesByTitle() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "see [[Beta]]"),
            makeEntry(id: "b", title: "Beta", content: "")
        ]
        let result = service.buildGraph(from: entries, tagColors: [:])
        XCTAssertEqual(result.graph.edges.count, 1)
        let edge = result.graph.edges[0]
        let aId = BlockGraphService.deterministicUUID(from: "a")
        let bId = BlockGraphService.deterministicUUID(from: "b")
        XCTAssertEqual(edge.sourceId, aId)
        XCTAssertEqual(edge.targetId, bId)
        XCTAssertEqual(edge.targetTitle, "Beta")
    }

    func testBuildGraphMarksUnresolvedEdges() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "see [[Nonexistent]]")
        ]
        let result = service.buildGraph(from: entries, tagColors: [:])
        XCTAssertEqual(result.graph.edges.count, 1)
        XCTAssertNil(result.graph.edges[0].targetId)
        XCTAssertEqual(result.graph.edges[0].targetTitle, "Nonexistent")
    }

    func testBuildGraphCountsIncomingWeight() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "[[Beta]]"),
            makeEntry(id: "b", title: "Beta", content: ""),
            makeEntry(id: "c", title: "Charlie", content: "[[Beta]]"),
            makeEntry(id: "d", title: "Delta", content: "[[Beta]]")
        ]
        let result = service.buildGraph(from: entries, tagColors: [:])
        let bId = BlockGraphService.deterministicUUID(from: "b")
        let beta = result.graph.nodes.first { $0.id == bId }
        XCTAssertNotNil(beta)
        XCTAssertEqual(beta?.weight, 3)
    }

    func testBuildGraphHandlesEmptyEntries() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let result = service.buildGraph(from: [], tagColors: [:])
        XCTAssertEqual(result.graph.nodes, [])
        XCTAssertEqual(result.graph.edges, [])
    }

    func testBuildGraphTitleResolutionIsCaseInsensitive() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "[[alpha]]"),
            makeEntry(id: "z", title: "Z", content: "")
        ]
        let result = service.buildGraph(from: entries, tagColors: [:])
        XCTAssertEqual(result.graph.edges.count, 1)
        let aId = BlockGraphService.deterministicUUID(from: "a")
        XCTAssertEqual(result.graph.edges[0].targetId, aId)
    }

    func testBuildGraphAppliesTagColors() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "", tagId: "t1")
        ]
        let green = Color.green
        let result = service.buildGraph(from: entries, tagColors: ["t1": green])
        XCTAssertEqual(result.graph.nodes.count, 1)
        XCTAssertEqual(result.graph.nodes[0].tagColor, green)
    }

    func testBuildGraphAppliesLayer() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "", layer: "review")
        ]
        let result = service.buildGraph(from: entries, tagColors: [:])
        XCTAssertEqual(result.graph.nodes.count, 1)
        XCTAssertEqual(result.graph.nodes[0].layer, .review)
    }

    func testFindOrphans_isolatedEntryReturned() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "no links here"),
            makeEntry(id: "b", title: "Beta", content: "[[Alpha]]")
        ]
        let orphans = service.findOrphans(in: entries)
        XCTAssertEqual(orphans.count, 0)

        let solo = [makeEntry(id: "x", title: "Solo", content: "nothing")]
        let soloOrphans = service.findOrphans(in: solo)
        XCTAssertEqual(soloOrphans.map(\.id), ["x"])
    }

    func testFindOrphans_excludesEntriesWithIncomingOrOutgoing() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "[[Beta]]"),
            makeEntry(id: "b", title: "Beta", content: ""),
            makeEntry(id: "c", title: "Charlie", content: "")
        ]
        let orphans = service.findOrphans(in: entries)
        XCTAssertEqual(orphans.map(\.id), ["c"])
    }

    func testFindUnresolvedLinks_returnsDanglingTargets() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "[[Nonexistent]] and [[Beta]]"),
            makeEntry(id: "b", title: "Beta", content: "")
        ]
        let unresolved = service.findUnresolvedLinks(in: entries)
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved[0].source.id, "a")
        XCTAssertEqual(unresolved[0].targetTitle, "Nonexistent")
    }

    @MainActor func testApplyDelta_matchesFullRebuildAfterMutation() async {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let initialEntries = [
            makeEntry(id: "a", title: "Alpha", content: "[[Beta]]"),
            makeEntry(id: "b", title: "Beta", content: ""),
            makeEntry(id: "c", title: "Charlie", content: "[[Alpha]]")
        ]
        let initial = service.buildGraph(from: initialEntries, tagColors: [:])

        let mutated = makeEntry(id: "a", title: "Alpha", content: "[[Beta]] [[Charlie]]")
        let nextEntries = [mutated, initialEntries[1], initialEntries[2]]
        let fullRebuild = service.buildGraph(from: nextEntries, tagColors: [:])

        let delta = await service.applyDelta(
            previous: initial,
            changedEntries: [mutated],
            removedBlockIds: [],
            allEntries: { nextEntries }
        )

        XCTAssertEqual(Set(delta.graph.nodes), Set(fullRebuild.graph.nodes))
        let deltaEdgeKeys = Set(delta.graph.edges.map { "\($0.sourceId)|\($0.targetId?.uuidString ?? "nil")|\($0.targetTitle)" })
        let fullEdgeKeys = Set(fullRebuild.graph.edges.map { "\($0.sourceId)|\($0.targetId?.uuidString ?? "nil")|\($0.targetTitle)" })
        XCTAssertEqual(deltaEdgeKeys, fullEdgeKeys)
        XCTAssertEqual(delta.idLookup, fullRebuild.idLookup)
    }

    func testFindNeighbors_resolvesIncomingAndOutgoing() {
        let service = BlockGraphService(indexCoordinator: .shared, tagStore: nil)
        let entries = [
            makeEntry(id: "a", title: "Alpha", content: "[[Beta]]"),
            makeEntry(id: "b", title: "Beta", content: "[[Charlie]] [[Ghost]]"),
            makeEntry(id: "c", title: "Charlie", content: ""),
            makeEntry(id: "d", title: "Delta", content: "[[Beta]]")
        ]
        let neighbors = service.findNeighbors(of: "b", in: entries)
        XCTAssertEqual(Set(neighbors.incoming.map(\.id)), Set(["a", "d"]))
        XCTAssertEqual(neighbors.outgoing.map(\.id), ["c"])
    }
}
