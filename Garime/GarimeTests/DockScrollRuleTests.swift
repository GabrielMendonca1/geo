import XCTest
@testable import Garime

final class DockScrollRuleTests: XCTestCase {
    func testTopOfListAlwaysRestoresTheFullSizeDock() {
        XCTAssertFalse(DockScrollRule.collapsed(was: true, from: 400, to: 0))
        XCTAssertFalse(DockScrollRule.collapsed(was: true, from: 400, to: DockScrollRule.topThreshold))
    }

    func testScrollingDownCollapsesAndScrollingUpRestores() {
        XCTAssertTrue(DockScrollRule.collapsed(was: false, from: 100, to: 160))
        XCTAssertFalse(DockScrollRule.collapsed(was: true, from: 160, to: 100))
    }

    func testJitterSmallerThanThresholdKeepsCurrentSize() {
        let jitter = DockScrollRule.moveThreshold - 1
        XCTAssertFalse(DockScrollRule.collapsed(was: false, from: 200, to: 200 + jitter))
        XCTAssertTrue(DockScrollRule.collapsed(was: true, from: 200, to: 200 - jitter))
    }

    func testBounceAboveTheTopIsNotReadAsScrollingUp() {
        XCTAssertFalse(DockScrollRule.collapsed(was: true, from: 5, to: -40))
    }
}
