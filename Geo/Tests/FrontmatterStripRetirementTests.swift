import XCTest
@testable import Geo

final class FrontmatterStripRetirementTests: XCTestCase {

    private var tempRoot: URL!
    private var defaults: UserDefaults!
    private let strippedKey = "geo.migration.frontmatterStripped.v1"

    override func setUp() {
        super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-strip-retire-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot.appendingPathComponent("Geo/Blocks"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "strip-retire-\(UUID().uuidString)")!
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        defaults = nil
        super.tearDown()
    }

    func testMarkRetiredSetsFlag() {
        let service = FrontmatterStripMigrationService(userDefaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: strippedKey))
        service.markRetired()
        XCTAssertTrue(defaults.bool(forKey: strippedKey))
    }

    func testRunIfNeededDoesNotStripFrontmatter() async {
        let blocksDir = tempRoot.appendingPathComponent("Geo/Blocks")
        let url = blocksDir.appendingPathComponent("Kept.md")
        let original = "---\ntype: permanent\nstatus: evergreen\n---\n# Title\n\nBody.\n"
        try? original.write(to: url, atomically: true, encoding: .utf8)

        let service = FrontmatterStripMigrationService(userDefaults: defaults)
        await service.runIfNeeded()

        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertEqual(after, original, "Frontmatter must NOT be stripped by the retired migration")
        XCTAssertTrue(defaults.bool(forKey: strippedKey), "runIfNeeded must mark retired so a restored backup cannot re-strip")
    }
}
