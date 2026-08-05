import XCTest
@testable import Garime

final class TerminalRulesTests: XCTestCase {
    func testUploadEndpointPath() {
        XCTAssertEqual(BridgeEndpoint.termUpload.path, "/term/upload")
    }

    func testReservedMacSessionIsPrunedOnLoad() {
        XCTAssertEqual(
            TerminalSessionList.normalized("vm:mobile,vm:mac,vm:build"),
            ["vm:mobile", "vm:build"]
        )
    }

    func testBareNamesAreQualifiedAndMacStaysOutOfVM() {
        XCTAssertEqual(TerminalSessionList.normalized("mobile,mac"), ["vm:mobile"])
        XCTAssertEqual(TerminalSessionList.normalized("mac:mac"), ["mac:mac"])
    }

    func testPruningEverythingFallsBackToDefault() {
        XCTAssertEqual(TerminalSessionList.normalized("vm:mac"), ["vm:mobile"])
        XCTAssertEqual(TerminalSessionList.normalized(""), ["vm:mobile"])
    }

    func testRenameEndpointPath() {
        XCTAssertEqual(
            BridgeEndpoint.termRename(session: "build", to: "deploy").path,
            "/term/rename?session=build&to=deploy"
        )
    }

    func testValidNameAcceptsAllowedCharacters() {
        XCTAssertTrue(TerminalSessionList.isValidName("build-2_x"))
        XCTAssertTrue(TerminalSessionList.isValidName(String(repeating: "a", count: 32)))
    }

    func testValidNameRejectsForbiddenCharactersAndLength() {
        XCTAssertFalse(TerminalSessionList.isValidName("meu nome"))
        XCTAssertFalse(TerminalSessionList.isValidName("build:2"))
        XCTAssertFalse(TerminalSessionList.isValidName("café"))
        XCTAssertFalse(TerminalSessionList.isValidName(String(repeating: "a", count: 33)))
    }

    func testValidNameRejectsReservedMacAndEmpty() {
        XCTAssertFalse(TerminalSessionList.isValidName("mac"))
        XCTAssertFalse(TerminalSessionList.isValidName(""))
    }

    func testRenamedSwapsEntryPreservingOrder() {
        XCTAssertEqual(
            TerminalSessionList.renamed(raw: "vm:mobile,vm:build,vm:logs", from: "vm:build", to: "deploy"),
            "vm:mobile,vm:deploy,vm:logs"
        )
    }

    func testRenamedIsNoOpWhenSourceAbsent() {
        XCTAssertEqual(
            TerminalSessionList.renamed(raw: "vm:mobile,vm:logs", from: "vm:build", to: "deploy"),
            "vm:mobile,vm:logs"
        )
        XCTAssertEqual(
            TerminalSessionList.renamed(raw: "vm:mobile,vm:build", from: "build", to: "deploy"),
            "vm:mobile,vm:build"
        )
    }

    func testRenamedKeepsMacEntryWhenSiblingIsRenamed() {
        XCTAssertEqual(
            TerminalSessionList.renamed(raw: "vm:build,mac:mac", from: "vm:build", to: "deploy"),
            "vm:deploy,mac:mac"
        )
    }

    func testHomeListKeepsMacOnceAndPreservesOrder() {
        XCTAssertEqual(
            TerminalSessionList.homeList("vm:mobile,mac:mac,vm:build"),
            ["vm:mobile", "mac:mac", "vm:build"]
        )
        XCTAssertEqual(
            TerminalSessionList.homeList("vm:mobile,vm:mobile"),
            ["vm:mobile", "mac:mac"]
        )
        XCTAssertEqual(TerminalSessionList.homeList(""), ["vm:mobile", "mac:mac"])
    }

    func testUploadNameStripsPathsAndUnsafeCharacters() {
        XCTAssertEqual(UploadName.sanitized("../../etc/passwd", fallback: "x"), "passwd")
        XCTAssertEqual(UploadName.sanitized("meu relatório (1).pdf", fallback: "x"), "meu_relat_rio__1_.pdf")
    }

    func testUploadNameRejectsDotPrefixesAndEmpty() {
        XCTAssertEqual(UploadName.sanitized(".bashrc", fallback: "x"), "bashrc")
        XCTAssertEqual(UploadName.sanitized("..", fallback: "x"), "x")
        XCTAssertEqual(UploadName.sanitized("", fallback: "x"), "x")
        XCTAssertEqual(UploadName.sanitized("...", fallback: "x"), "x")
    }

    func testUploadNameCapsAtEightyCharacters() {
        let long = String(repeating: "a", count: 200) + ".txt"
        let name = UploadName.sanitized(long, fallback: "x")
        XCTAssertEqual(name.count, 80)
        XCTAssertTrue(name.hasSuffix(".txt"))
    }
}
