import XCTest
@testable import Geo

final class OpenFileRouterTests: XCTestCase {
    private let vault = URL(fileURLWithPath: "/Users/geo-test/Library/Application Support/Geo/Blocks", isDirectory: true)

    private func norm(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    func testVaultFileAlreadyIndexedOpensExistingNeverCreates() {
        let file = vault.appendingPathComponent("Note.md")
        let outcomes = OpenFileRouter.resolve(
            urls: [file],
            vaultDirectory: vault,
            existingByPath: [norm(file).path: "block-123"]
        )
        XCTAssertEqual(outcomes, [.openExisting(blockId: "block-123")])
        XCTAssertFalse(outcomes.contains { if case .create = $0 { return true } else { return false } })
    }

    func testVaultFileNotIndexedCreates() {
        let file = vault.appendingPathComponent("Fresh.md")
        let outcomes = OpenFileRouter.resolve(urls: [file], vaultDirectory: vault, existingByPath: [:])
        XCTAssertEqual(outcomes, [.create(url: norm(file))])
    }

    func testExternalFileRoutesToExternal() {
        let file = URL(fileURLWithPath: "/Users/geo-test/Documents/External.md")
        let outcomes = OpenFileRouter.resolve(urls: [file], vaultDirectory: vault, existingByPath: [:])
        XCTAssertEqual(outcomes, [.external(url: norm(file))])
    }

    func testUnsupportedExtensionIgnored() {
        let file = vault.appendingPathComponent("image.png")
        let outcomes = OpenFileRouter.resolve(urls: [file], vaultDirectory: vault, existingByPath: [:])
        XCTAssertTrue(outcomes.isEmpty)
    }
}
