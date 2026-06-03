import XCTest
@testable import Geo

final class Phase1LayerReadTests: XCTestCase {

    // MARK: - MarkdownConverter.normalizedLayer / layer(in:)

    func testNormalizedLayerReturnsNilForAbsentAndEmpty() {
        XCTAssertNil(MarkdownConverter.normalizedLayer(nil))
        XCTAssertNil(MarkdownConverter.normalizedLayer(""))
        XCTAssertNil(MarkdownConverter.normalizedLayer("   "))
    }

    func testNormalizedLayerParsesEachRawValue() {
        XCTAssertEqual(MarkdownConverter.normalizedLayer("user"), .user)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("agent"), .agent)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("review"), .review)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("shared"), .shared)
    }

    func testNormalizedLayerToleratesQuotesAndCase() {
        XCTAssertEqual(MarkdownConverter.normalizedLayer("\"agent\""), .agent)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("'shared'"), .shared)
        XCTAssertEqual(MarkdownConverter.normalizedLayer("AGENT"), .agent)
        XCTAssertEqual(MarkdownConverter.normalizedLayer(" Review "), .review)
    }

    func testNormalizedLayerReturnsNilForInvalidValue() {
        XCTAssertNil(MarkdownConverter.normalizedLayer("bogus"))
        XCTAssertNil(MarkdownConverter.normalizedLayer("Voce"))
    }

    func testLayerInReturnsNilWhenNoFrontmatter() {
        XCTAssertNil(MarkdownConverter.shared.layer(in: "# Just a heading\n\nBody.\n"))
    }

    func testLayerInReturnsNilWhenFrontmatterLacksLayer() {
        XCTAssertNil(MarkdownConverter.shared.layer(in: "---\ntype: fleeting\n---\n# X\n"))
    }

    func testLayerInParsesPresentLayer() {
        XCTAssertEqual(MarkdownConverter.shared.layer(in: "---\nlayer: shared\n---\n# X\n"), .shared)
    }

    // MARK: - AgentAuthorization input is frontmatter-derived

    private func entity(id: String, frontmatterLayer: BlockLayer) -> BlockEntity {
        let markdown = "---\nlayer: \(frontmatterLayer.rawValue)\n---\n# \(id)\n"
        let resolved = MarkdownConverter.shared.layer(in: markdown) ?? .default
        return BlockEntity(
            id: id,
            title: id,
            date: Date(),
            lastEdited: Date(),
            markdown: markdown,
            url: URL(fileURLWithPath: "/tmp/\(id).md"),
            tagId: nil,
            metadata: BlockEntity.Metadata(layer: resolved)
        )
    }

    func testAuthorizeDeniesUpdateOnFrontmatterUserLayer() async throws {
        let repo = SingleBlockRepo(entity: entity(id: "U", frontmatterLayer: .user))
        let result = try await AgentAuthorization.authorizeWrite(.update, id: "U", in: repo)
        switch result {
        case .ok: XCTFail("Expected denial for .user layer")
        case .denied: break
        }
    }

    func testAuthorizeAllowsUpdateOnFrontmatterReviewLayer() async throws {
        let repo = SingleBlockRepo(entity: entity(id: "R", frontmatterLayer: .review))
        let result = try await AgentAuthorization.authorizeWrite(.update, id: "R", in: repo)
        switch result {
        case .ok: break
        case .denied(let r): XCTFail("Expected allow for .review layer, got \(r)")
        }
    }

    func testAuthorizeAllowsUpdateOnFrontmatterAgentLayer() async throws {
        let repo = SingleBlockRepo(entity: entity(id: "A", frontmatterLayer: .agent))
        let result = try await AgentAuthorization.authorizeWrite(.update, id: "A", in: repo)
        switch result {
        case .ok: break
        case .denied(let r): XCTFail("Expected allow for .agent layer, got \(r)")
        }
    }
}

private struct SingleBlockRepo: BlocksRepository, @unchecked Sendable {
    let entity: BlockEntity

    func observe() -> AsyncStream<[BlockEntity]> {
        AsyncStream { c in c.yield([entity]); c.finish() }
    }
    func search(matching query: String) async throws -> [BlockEntity] { [entity] }
    func list() async throws -> [BlockEntity] { [entity] }
    func get(id: String) async throws -> BlockEntity? { id == entity.id ? entity : nil }
    func create(title: String, markdown: String) async throws -> BlockEntity { entity }
    func update(id: String, markdown: String) async throws {}
    func delete(id: String) async throws {}
    func setTag(blockId: String, tagId: String?) async throws {}
    func setFullWidth(blockId: String, isFullWidth: Bool) async throws {}
    func setLayer(blockId: String, layer: BlockLayer) async throws {}
    func setType(blockId: String, type: BlockType) async throws {}
    func setStatus(blockId: String, status: String?) async throws {}
    func checkboxes(in blockId: String) async -> [BlockCheckbox] { [] }
    func toggleCheckbox(in blockId: String, lineNumber: Int) async throws {}
    func mutateFrontmatter(blockId: String, merge: [String: AnyCodableValue]) async throws -> Int { 0 }
    @MainActor func saveSync(id: String, markdown: String) -> Bool { false }
}
