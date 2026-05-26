import XCTest
@testable import Geo

final class BlockPrefixDetectorTests: XCTestCase {

    func testHashSpace_h1() {
        XCTAssertEqual(BlockPrefixDetector.detect("# "), .convert(kind: .heading(level: 1), remainingContent: ""))
    }

    func testHashSpace_h2() {
        XCTAssertEqual(BlockPrefixDetector.detect("## "), .convert(kind: .heading(level: 2), remainingContent: ""))
    }

    func testHashSpace_h3() {
        XCTAssertEqual(BlockPrefixDetector.detect("### "), .convert(kind: .heading(level: 3), remainingContent: ""))
    }

    func testHashSpace_h4() {
        XCTAssertEqual(BlockPrefixDetector.detect("#### "), .convert(kind: .heading(level: 4), remainingContent: ""))
    }

    func testHashSpace_h5() {
        XCTAssertEqual(BlockPrefixDetector.detect("##### "), .convert(kind: .heading(level: 5), remainingContent: ""))
    }

    func testHashSpace_h6() {
        XCTAssertEqual(BlockPrefixDetector.detect("###### "), .convert(kind: .heading(level: 6), remainingContent: ""))
    }

    func testHashSpace_sevenHashes_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("####### "))
    }

    func testHash_noSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("#"))
    }

    func testHash_leadingSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect(" # "))
    }

    func testBullet_dash() {
        XCTAssertEqual(BlockPrefixDetector.detect("- "), .convert(kind: .bulletItem(marker: "-"), remainingContent: ""))
    }

    func testBullet_asterisk() {
        XCTAssertEqual(BlockPrefixDetector.detect("* "), .convert(kind: .bulletItem(marker: "*"), remainingContent: ""))
    }

    func testBullet_plus() {
        XCTAssertEqual(BlockPrefixDetector.detect("+ "), .convert(kind: .bulletItem(marker: "+"), remainingContent: ""))
    }

    func testBullet_doubleDash_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("-- "))
    }

    func testBullet_dashNoSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("-"))
    }

    func testOrdered_one() {
        XCTAssertEqual(BlockPrefixDetector.detect("1. "), .convert(kind: .orderedItem(number: 1), remainingContent: ""))
    }

    func testOrdered_fortyTwo() {
        XCTAssertEqual(BlockPrefixDetector.detect("42. "), .convert(kind: .orderedItem(number: 42), remainingContent: ""))
    }

    func testOrdered_zero() {
        XCTAssertEqual(BlockPrefixDetector.detect("0. "), .convert(kind: .orderedItem(number: 0), remainingContent: ""))
    }

    func testOrdered_noSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("1."))
    }

    func testOrdered_letter_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("a. "))
    }

    func testBlockquote_singleAngle() {
        XCTAssertEqual(BlockPrefixDetector.detect("> "), .convert(kind: .blockquote, remainingContent: ""))
    }

    func testBlockquote_doubleAngle_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect(">> "))
    }

    func testCheckbox_emptyBrackets() {
        XCTAssertEqual(BlockPrefixDetector.detect("[] "), .convert(kind: .checkboxItem(checked: false, marker: "-"), remainingContent: ""))
    }

    func testCheckbox_spaceInBrackets() {
        XCTAssertEqual(BlockPrefixDetector.detect("[ ] "), .convert(kind: .checkboxItem(checked: false, marker: "-"), remainingContent: ""))
    }

    func testCheckedCheckbox_lowerX() {
        XCTAssertEqual(BlockPrefixDetector.detect("[x] "), .convert(kind: .checkboxItem(checked: true, marker: "-"), remainingContent: ""))
    }

    func testCheckedCheckbox_upperX() {
        XCTAssertEqual(BlockPrefixDetector.detect("[X] "), .convert(kind: .checkboxItem(checked: true, marker: "-"), remainingContent: ""))
    }

    func testCheckbox_invalidLetter_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("[y] "))
    }

    func testCheckbox_paddedX_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("[ x ] "))
    }

    func testFence_tripleBacktick_insertsCodeBlock() {
        XCTAssertEqual(BlockPrefixDetector.detect("``` "), .insertCodeBlock)
    }

    func testFence_doubleDollar_insertsMathBlock() {
        XCTAssertEqual(BlockPrefixDetector.detect("$$ "), .insertMathBlock)
    }

    func testFence_singleBacktick_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("` "))
    }

    func testFence_doubleBacktick_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("`` "))
    }

    func testFence_singleDollar_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("$ "))
    }

    func testFence_tripleDollar_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("$$$ "))
    }

    func testEmptyString_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect(""))
    }

    func testJustSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect(" "))
    }

    func testPlainText_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("hello "))
    }

    func testHashWithText_noTrailingSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("# heading text"))
    }

    func testHashWithText_andTrailingSpace_returnsNil() {
        XCTAssertNil(BlockPrefixDetector.detect("# foo "))
    }
}
