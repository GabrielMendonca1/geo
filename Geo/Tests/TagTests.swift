import XCTest
@testable import Geo

final class TagTests: XCTestCase {
    func testPrefersDarkTextForBrightColor() {
        let color = TagColor(red: 1, green: 1, blue: 1)

        XCTAssertTrue(color.prefersDarkText)
    }

    func testPrefersDarkTextFalseForDarkColor() {
        let color = TagColor(red: 0, green: 0, blue: 0)

        XCTAssertFalse(color.prefersDarkText)
    }

    func testTagColorCodableRoundTrip() throws {
        let original = TagColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 0.9)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TagColor.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testTagStoreErrorDescriptionEmptyName() {
        XCTAssertEqual(TagStoreError.emptyName.errorDescription, "Tag name cannot be empty.")
    }

    func testTagStoreErrorDescriptionDuplicateName() {
        XCTAssertEqual(TagStoreError.duplicateName.errorDescription, "A tag with this name already exists.")
    }

    func testTagStoreErrorDescriptionNotFound() {
        XCTAssertEqual(TagStoreError.notFound.errorDescription, "Tag not found.")
    }
}
