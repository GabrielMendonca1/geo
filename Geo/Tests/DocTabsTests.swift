import XCTest
@testable import Geo

@MainActor
final class DocTabsTests: XCTestCase {
    private func ref(_ id: String, title: String? = nil) -> OpenDocRef {
        OpenDocRef(id: id, title: title ?? id.uppercased(), url: URL(fileURLWithPath: "/tmp/\(id).md"))
    }

    func testOpenActivatesAndTracks() {
        let m = DocTabsModel()
        m.open(ref("a"))
        XCTAssertEqual(m.openRefs.map(\.id), ["a"])
        XCTAssertEqual(m.activeId, "a")
        XCTAssertTrue(m.liveIds.contains("a"))
        XCTAssertEqual(m.ref("a")?.title, "A")   // O(1) lookup
    }

    func testOpenManyKeepsOrderAndActivatesLast() {
        let m = DocTabsModel()
        ["a", "b", "c"].forEach { m.open(ref($0)) }
        XCTAssertEqual(m.openRefs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(m.activeId, "c")
    }

    func testReopenDoesNotDuplicate() {
        let m = DocTabsModel()
        m.open(ref("a")); m.open(ref("b")); m.open(ref("a"))
        XCTAssertEqual(m.openRefs.map(\.id), ["a", "b"])
        XCTAssertEqual(m.activeId, "a")
    }

    func testCloseActiveMovesToNeighbor() {
        let m = DocTabsModel()
        ["a", "b", "c"].forEach { m.open(ref($0)) }
        m.activate("b")
        m.close("b")
        XCTAssertEqual(m.openRefs.map(\.id), ["a", "c"])
        XCTAssertEqual(m.activeId, "c")
    }

    func testLRUBoundsLiveEditorsButKeepsTabs() {
        let m = DocTabsModel(maxLive: 2)
        ["a", "b", "c"].forEach { m.open(ref($0)) }
        XCTAssertEqual(m.openRefs.count, 3)              // all three remain as tabs
        XCTAssertEqual(m.liveIds.count, 2)               // only two editors mounted
        XCTAssertTrue(m.liveIds.contains("c"))           // active
        XCTAssertFalse(m.liveIds.contains("a"))          // coldest evicted
    }

    func testActiveIsNeverEvicted() {
        let m = DocTabsModel(maxLive: 1)
        ["a", "b", "c"].forEach { m.open(ref($0)) }
        XCTAssertEqual(m.liveIds, ["c"])
        XCTAssertEqual(m.activeId, "c")
    }

    func testResyncDropsMissingAndRetitles() {
        let m = DocTabsModel()
        ["a", "b"].forEach { m.open(ref($0)) }           // b active
        m.resync { id in id == "a" ? OpenDocRef(id: "a", title: "Renamed", url: URL(fileURLWithPath: "/tmp/a.md")) : nil }
        XCTAssertEqual(m.openRefs.map(\.id), ["a"])
        XCTAssertEqual(m.ref("a")?.title, "Renamed")
        XCTAssertEqual(m.activeId, "a")                  // active b vanished → falls back to a
    }

    func testCloseAllResets() {
        let m = DocTabsModel()
        ["a", "b"].forEach { m.open(ref($0)) }
        m.closeAll()
        XCTAssertTrue(m.openRefs.isEmpty)
        XCTAssertNil(m.activeId)
        XCTAssertTrue(m.liveIds.isEmpty)
    }
}
