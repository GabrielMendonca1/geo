import XCTest
@testable import Geo

final class BlockLayerFolderTests: XCTestCase {
    func testBlockLayerFromFolderSegmentMapsAsciiSlugs() {
        XCTAssertEqual(BlockLayer(folderSegment: "Voce"), .user)
        XCTAssertEqual(BlockLayer(folderSegment: "Agente"), .agent)
        XCTAssertEqual(BlockLayer(folderSegment: "Revisao"), .review)
        XCTAssertEqual(BlockLayer(folderSegment: "Compartilhado"), .shared)
    }

    func testBlockLayerFolderNameRoundTrips() {
        for layer in BlockLayer.allCases {
            XCTAssertEqual(BlockLayer(folderSegment: layer.folderName), layer)
        }
    }

    func testBlockLayerUnknownSegmentReturnsNil() {
        XCTAssertNil(BlockLayer(folderSegment: "permanent"))
        XCTAssertNil(BlockLayer(folderSegment: ""))
        XCTAssertNil(BlockLayer(folderSegment: "Daily"))
        XCTAssertNil(BlockLayer(folderSegment: "Dias"))
    }

    func testBlockLayerFolderSegmentCaseInsensitive() {
        XCTAssertEqual(BlockLayer(folderSegment: "voce"), .user)
        XCTAssertEqual(BlockLayer(folderSegment: "AGENTE"), .agent)
    }

    func testBlockLayerFolderSegmentNFCInsensitive() {
        let nfd = "Compartilhado".decomposedStringWithCanonicalMapping
        XCTAssertEqual(BlockLayer(folderSegment: nfd), .shared)
    }
}
