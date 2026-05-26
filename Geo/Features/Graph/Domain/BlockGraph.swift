import Foundation
import SwiftUI

struct GraphNode: Identifiable, Hashable {
    let id: UUID
    let title: String
    let tagColor: Color?
    let type: BlockType
    let layer: BlockLayer
    let weight: Int
}

struct GraphEdge: Identifiable, Hashable {
    let id: UUID
    let sourceId: UUID
    let targetId: UUID?
    let targetTitle: String
}

struct BlockGraph: Hashable {
    let nodes: [GraphNode]
    let edges: [GraphEdge]

    static let empty = BlockGraph(nodes: [], edges: [])
}
