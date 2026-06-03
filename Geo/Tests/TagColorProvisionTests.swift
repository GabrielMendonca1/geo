import XCTest
@testable import Geo

@MainActor
final class TagColorProvisionTests: XCTestCase {

    private var tempRoot: URL!
    private var store: TagStore!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent("geo-tagcolor-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = TagStore(baseURL: tempRoot, enableWatcher: false)
    }

    override func tearDown() async throws {
        store = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        try await super.tearDown()
    }

    func testCanonicalNameLowercasesAndNFC() {
        XCTAssertEqual(TagStore.canonicalName("ARC"), "arc")
        XCTAssertEqual(TagStore.canonicalName("  Arc  "), "arc")
        let nfd = "Introduc\u{0327}a\u{0303}o"
        let nfc = "Introdução"
        XCTAssertEqual(TagStore.canonicalName(nfd), TagStore.canonicalName(nfc))
    }

    func testEnsureColorAutoProvisionsDefaultOnFirstSighting() {
        XCTAssertNil(store.color(forName: "newtag"))
        let provisioned = store.ensureColor(forName: "newtag")
        XCTAssertEqual(TagStore.canonicalName(provisioned.name), "newtag")
        XCTAssertNotNil(store.color(forName: "newtag"))
    }

    func testEnsureColorIsIdempotentAndCollapsesCaseVariants() {
        let first = store.ensureColor(forName: "ARC")
        let second = store.ensureColor(forName: "arc")
        XCTAssertEqual(first.color, second.color)
        XCTAssertEqual(store.tags.filter { TagStore.canonicalName($0.name) == "arc" }.count, 1)
    }

    func testDefaultColorDeterministicPerName() {
        XCTAssertEqual(TagStore.defaultColor(forName: "arc"), TagStore.defaultColor(forName: "arc"))
    }

    func testCreateTagRejectsNFCDuplicate() {
        let r1 = store.createTag(name: "Introdução", color: TagColor(red: 0.1, green: 0.2, blue: 0.3))
        guard case .success = r1 else { return XCTFail("first create should succeed") }
        let nfd = "Introduc\u{0327}a\u{0303}o"
        let r2 = store.createTag(name: nfd, color: TagColor(red: 0.4, green: 0.5, blue: 0.6))
        guard case .failure(let err) = r2 else { return XCTFail("NFD duplicate should be rejected") }
        XCTAssertEqual(err, .duplicateName)
    }

    func testTagsJsonShrinksToNameKeyedSchemaAndRoundTrips() throws {
        _ = store.createTag(name: "Work", color: TagColor(red: 0.2, green: 0.4, blue: 0.6))
        store.ensureColor(forName: "ARC")

        let exp = expectation(description: "tags.json written")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let url = tempRoot.appendingPathComponent("Geo/tags.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json, "shrunk schema is a name-keyed object, not an array")
        XCTAssertNotNil(json?["work"], "canonical name is the key")
        XCTAssertNotNil(json?["arc"])

        let decoded = try TagStore.decodeTags(data)
        XCTAssertTrue(decoded.contains { TagStore.canonicalName($0.name) == "work" })
        XCTAssertTrue(decoded.contains { TagStore.canonicalName($0.name) == "arc" })
    }

    func testDecoderToleratesLegacyUUIDArraySchema() throws {
        let legacy = """
        [{"id":"AAAA-1111","name":"Legacy","color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1.0}}]
        """
        let decoded = try TagStore.decodeTags(Data(legacy.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.name, "Legacy")
        XCTAssertEqual(decoded.first?.id, "AAAA-1111")
    }
}
