import AppKit
import SwiftUI

struct GraphPhysicsNode {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var pinned: Bool
}

struct SimEdge {
    let source: UUID
    let target: UUID
    let restLength: CGFloat
    let stiffness: CGFloat
}

struct GraphEdgeKey: Hashable {
    let source: UUID
    let target: UUID
}

struct GraphRenderSnapshot {
    var positions: [UUID: CGPoint] = [:]
    var radii: [UUID: CGFloat] = [:]
}

// Barnes-Hut quadtree. Each cell is either empty, a leaf (one or more
// near-coincident bodies that resolve to exact pairwise forces) or an
// internal node split into 4 quadrants. We aggregate body count (mass) and
// center-of-mass so a far cell can be approximated by a single point.
final class QuadCell {
    var minX: CGFloat
    var minY: CGFloat
    var size: CGFloat
    var mass: CGFloat = 0
    var comX: CGFloat = 0
    var comY: CGFloat = 0
    var bodyIndex: Int = -1
    var bodies: [Int]? = nil
    var children: [QuadCell?] = [nil, nil, nil, nil]
    var isInternal = false

    init(minX: CGFloat, minY: CGFloat, size: CGFloat) {
        self.minX = minX
        self.minY = minY
        self.size = size
    }

    func quadrant(forX x: CGFloat, y: CGFloat) -> Int {
        let mid = size * 0.5
        let east = x >= minX + mid
        let south = y >= minY + mid
        return (south ? 2 : 0) + (east ? 1 : 0)
    }

    func makeChild(_ q: Int) -> QuadCell {
        let half = size * 0.5
        let cx = minX + (q & 1 == 1 ? half : 0)
        let cy = minY + (q & 2 == 2 ? half : 0)
        let child = QuadCell(minX: cx, minY: cy, size: half)
        children[q] = child
        return child
    }
}

final class GraphSimulation: ObservableObject {
    @Published private(set) var isSettled = false

    private var nodes: [UUID: GraphPhysicsNode] = [:]
    private var simEdges: [SimEdge] = []
    private var nodeOrder: [UUID] = []
    private var forces: [UUID: CGVector] = [:]
    private var separation: [UUID: CGVector] = [:]
    private let snapshotLock = NSLock()
    private var storedSnapshot = GraphRenderSnapshot()

    // Gravity is weak so orphans/low-degree nodes drift out into a sparse halo
    // instead of being reeled back into a uniform-density core; global Barnes-Hut
    // repulsion (no distance cutoff) then carves dense clusters into lobes.
    private let centerStrength: CGFloat = 0.0004
    private let repulsionStrength: CGFloat = 9000
    private let theta: CGFloat = 0.85
    private let minCellSize: CGFloat = 0.5
    private let springStiffness: CGFloat = 0.02
    private let springLength: CGFloat = 150
    private let damping: CGFloat = 0.86
    private let maxVelocity: CGFloat = 14
    private let kineticThreshold: CGFloat = 0.018
    private let timeStep: CGFloat = 0.85
    private var iterationCount = 0
    private let maxIterations = 1400
    private var quietStreak = 0
    private let quietStreakThreshold = 6

    var isEmpty: Bool { nodes.isEmpty }

    var positionsSnapshot: [UUID: CGPoint] { nodes.mapValues(\.position) }

    var renderSnapshot: GraphRenderSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return storedSnapshot
    }

    private func publishSnapshot() {
        let snapshot = GraphRenderSnapshot(positions: nodes.mapValues(\.position), radii: nodes.mapValues(\.radius))
        snapshotLock.lock()
        storedSnapshot = snapshot
        snapshotLock.unlock()
    }

    var fitItems: [(position: CGPoint, radius: CGFloat)] {
        nodes.values.map { ($0.position, $0.radius) }
    }

    func seedCachedPositions(_ positions: [UUID: CGPoint], settled: Bool) {
        for (id, pos) in positions where nodes[id] == nil {
            nodes[id] = GraphPhysicsNode(position: pos, velocity: .zero, radius: 8, pinned: false)
        }
        if settled { isSettled = true }
        publishSnapshot()
    }

    func ingest(graph: BlockGraph) {
        let canvasSize: CGFloat = 720
        var newNodes: [UUID: GraphPhysicsNode] = [:]
        var newOrder: [UUID] = []
        var degree: [UUID: Int] = [:]
        for edge in graph.edges {
            degree[edge.sourceId, default: 0] += 1
            if let target = edge.targetId {
                degree[target, default: 0] += 1
            }
        }

        let priorNodeIDs = Set(nodeOrder)
        var addedCount = 0

        for (idx, node) in graph.nodes.enumerated() {
            let radius = Self.radius(for: degree[node.id] ?? 0) * Self.typeWeight(for: node.type)
            let prior = nodes[node.id]
            if prior == nil { addedCount += 1 }
            let position = prior?.position ?? Self.seedPosition(index: idx, total: max(graph.nodes.count, 1), canvas: canvasSize)
            let velocity = prior?.velocity ?? .zero
            newNodes[node.id] = GraphPhysicsNode(position: position, velocity: velocity, radius: radius, pinned: prior?.pinned ?? false)
            newOrder.append(node.id)
        }

        // Springs are degree-softened (d3-style): hub edges relax so dense MOCs
        // neither collapse their leaves nor drag whole clusters into each other.
        var newEdges: [SimEdge] = []
        for edge in graph.edges {
            guard let target = edge.targetId,
                  let targetNode = newNodes[target],
                  let sourceNode = newNodes[edge.sourceId] else { continue }
            let degS = max(degree[edge.sourceId] ?? 1, 1)
            let degT = max(degree[target] ?? 1, 1)
            let softening = 1 / sqrt(CGFloat(min(degS, degT)))
            newEdges.append(SimEdge(
                source: edge.sourceId,
                target: target,
                restLength: springLength + sourceNode.radius + targetNode.radius,
                stiffness: softening
            ))
        }

        let newNodeIDs = Set(newOrder)
        let removedCount = priorNodeIDs.subtracting(newNodeIDs).count
        let nodeStructural = addedCount > 0 || removedCount > 0

        var priorGraphEdgeKeys = Set<GraphEdgeKey>()
        for edge in simEdges {
            priorGraphEdgeKeys.insert(GraphEdgeKey(source: edge.source, target: edge.target))
        }
        var newGraphEdgeKeys = Set<GraphEdgeKey>()
        for edge in newEdges {
            newGraphEdgeKeys.insert(GraphEdgeKey(source: edge.source, target: edge.target))
        }
        let edgeStructural = priorGraphEdgeKeys != newGraphEdgeKeys
        let firstIngest = priorNodeIDs.isEmpty

        nodes = newNodes
        nodeOrder = newOrder
        simEdges = newEdges

        if firstIngest || nodeStructural {
            isSettled = false
            iterationCount = 0
        } else if edgeStructural {
            isSettled = false
            iterationCount = max(iterationCount, maxIterations - 200)
        }
        publishSnapshot()
    }

    func step() {
        guard !isSettled, !nodes.isEmpty else { return }
        iterationCount += 1

        forces.removeAll(keepingCapacity: true)
        separation.removeAll(keepingCapacity: true)
        for id in nodeOrder { forces[id] = .zero }

        let count = nodeOrder.count
        var px = [CGFloat](repeating: 0, count: count)
        var py = [CGFloat](repeating: 0, count: count)
        var radii = [CGFloat](repeating: 0, count: count)
        for i in 0..<count {
            guard let node = nodes[nodeOrder[i]] else { continue }
            px[i] = node.position.x
            py[i] = node.position.y
            radii[i] = node.radius
        }

        // Global Barnes-Hut repulsion: one quadtree per step, no distance cutoff.
        // Far cells (s/d < theta) collapse to their center-of-mass; near bodies
        // recurse to exact leaves, which is also where collision separation lands.
        if let root = buildQuadtree(px: px, py: py) {
            var fx = [CGFloat](repeating: 0, count: count)
            var fy = [CGFloat](repeating: 0, count: count)
            var sx = [CGFloat](repeating: 0, count: count)
            var sy = [CGFloat](repeating: 0, count: count)
            for i in 0..<count {
                applyRepulsion(cell: root, i: i, px: px, py: py, radii: radii, fx: &fx, fy: &fy, sx: &sx, sy: &sy)
            }
            for i in 0..<count {
                let id = nodeOrder[i]
                forces[id]?.dx += fx[i]
                forces[id]?.dy += fy[i]
                if sx[i] != 0 || sy[i] != 0 {
                    separation[id] = CGVector(dx: sx[i], dy: sy[i])
                }
            }
        }

        for edge in simEdges {
            guard let source = nodes[edge.source], let target = nodes[edge.target] else { continue }
            let dx = target.position.x - source.position.x
            let dy = target.position.y - source.position.y
            let dist = max(sqrt(dx * dx + dy * dy), 0.01)
            let displacement = dist - edge.restLength
            let k = springStiffness * edge.stiffness
            let fx = (dx / dist) * displacement * k
            let fy = (dy / dist) * displacement * k
            forces[edge.source]?.dx += fx
            forces[edge.source]?.dy += fy
            forces[edge.target]?.dx -= fx
            forces[edge.target]?.dy -= fy
        }

        for id in nodeOrder {
            guard let node = nodes[id] else { continue }
            forces[id]?.dx -= node.position.x * centerStrength
            forces[id]?.dy -= node.position.y * centerStrength
        }

        var totalKE: CGFloat = 0
        for id in nodeOrder {
            guard var node = nodes[id], let force = forces[id] else { continue }
            if node.pinned {
                node.velocity = .zero
                nodes[id] = node
                continue
            }
            node.velocity.dx = (node.velocity.dx + force.dx * timeStep) * damping
            node.velocity.dy = (node.velocity.dy + force.dy * timeStep) * damping
            let speedSq = node.velocity.dx * node.velocity.dx + node.velocity.dy * node.velocity.dy
            if speedSq > maxVelocity * maxVelocity {
                let speed = sqrt(speedSq)
                node.velocity.dx = node.velocity.dx / speed * maxVelocity
                node.velocity.dy = node.velocity.dy / speed * maxVelocity
            }
            node.position.x += node.velocity.dx * timeStep
            node.position.y += node.velocity.dy * timeStep
            totalKE += speedSq
            nodes[id] = node
        }

        for (id, shift) in separation {
            guard var node = nodes[id], !node.pinned else { continue }
            node.position.x += shift.dx
            node.position.y += shift.dy
            nodes[id] = node
        }

        let avgKE = totalKE / CGFloat(max(nodeOrder.count, 1))
        if avgKE < kineticThreshold {
            quietStreak += 1
        } else {
            quietStreak = 0
        }
        if quietStreak >= quietStreakThreshold || iterationCount > maxIterations {
            for id in nodeOrder where !(nodes[id]?.pinned ?? true) {
                nodes[id]?.velocity = .zero
            }
            quietStreak = 0
            isSettled = true
        }
        publishSnapshot()
    }

    private func buildQuadtree(px: [CGFloat], py: [CGFloat]) -> QuadCell? {
        let count = px.count
        guard count > 0 else { return nil }
        var minX = px[0], maxX = px[0], minY = py[0], maxY = py[0]
        for i in 1..<count {
            if px[i] < minX { minX = px[i] }
            if px[i] > maxX { maxX = px[i] }
            if py[i] < minY { minY = py[i] }
            if py[i] > maxY { maxY = py[i] }
        }
        let side = max(maxX - minX, maxY - minY, 1)
        let root = QuadCell(minX: minX, minY: minY, size: side)
        for i in 0..<count {
            insert(into: root, body: i, px: px, py: py)
        }
        return root
    }

    private func insert(into cell: QuadCell, body i: Int, px: [CGFloat], py: [CGFloat]) {
        cell.mass += 1
        cell.comX += px[i]
        cell.comY += py[i]

        if !cell.isInternal {
            if cell.bodyIndex == -1 && cell.bodies == nil {
                cell.bodyIndex = i
                return
            }
            // Cap subdivision at coincident/sub-pixel cells: keep bodies together
            // in one leaf and resolve them with exact pairwise forces. Prevents
            // infinite recursion on identical points.
            if cell.size <= minCellSize {
                if cell.bodies == nil {
                    cell.bodies = cell.bodyIndex == -1 ? [] : [cell.bodyIndex]
                    cell.bodyIndex = -1
                }
                cell.bodies?.append(i)
                return
            }
            cell.isInternal = true
            let existing = cell.bodyIndex
            cell.bodyIndex = -1
            if existing != -1 {
                let q = cell.quadrant(forX: px[existing], y: py[existing])
                let child = cell.children[q] ?? cell.makeChild(q)
                insert(into: child, body: existing, px: px, py: py)
            }
        }

        let q = cell.quadrant(forX: px[i], y: py[i])
        let child = cell.children[q] ?? cell.makeChild(q)
        insert(into: child, body: i, px: px, py: py)
    }

    private func applyRepulsion(cell: QuadCell, i: Int, px: [CGFloat], py: [CGFloat], radii: [CGFloat], fx: inout [CGFloat], fy: inout [CGFloat], sx: inout [CGFloat], sy: inout [CGFloat]) {
        guard cell.mass > 0 else { return }

        if !cell.isInternal {
            if let bodies = cell.bodies {
                for j in bodies where j != i {
                    pairForce(i: i, j: j, px: px, py: py, radii: radii, fx: &fx, fy: &fy, sx: &sx, sy: &sy)
                }
            } else if cell.bodyIndex != -1 && cell.bodyIndex != i {
                pairForce(i: i, j: cell.bodyIndex, px: px, py: py, radii: radii, fx: &fx, fy: &fy, sx: &sx, sy: &sy)
            }
            return
        }

        let comX = cell.comX / cell.mass
        let comY = cell.comY / cell.mass
        let dx = px[i] - comX
        let dy = py[i] - comY
        let distSq = max(dx * dx + dy * dy, 0.01)
        let dist = sqrt(distSq)
        // Theta criterion: if the cell subtends a small enough angle (s/d < theta)
        // treat its whole subtree as one body at the center-of-mass.
        if cell.size / dist < theta {
            let force = repulsionStrength * cell.mass / distSq
            fx[i] += (dx / dist) * force
            fy[i] += (dy / dist) * force
            return
        }
        for child in cell.children {
            if let child {
                applyRepulsion(cell: child, i: i, px: px, py: py, radii: radii, fx: &fx, fy: &fy, sx: &sx, sy: &sy)
            }
        }
    }

    private func pairForce(i: Int, j: Int, px: [CGFloat], py: [CGFloat], radii: [CGFloat], fx: inout [CGFloat], fy: inout [CGFloat], sx: inout [CGFloat], sy: inout [CGFloat]) {
        var dx = px[i] - px[j]
        var dy = py[i] - py[j]
        var distSq = dx * dx + dy * dy
        if distSq < 0.01 {
            // Jitter coincident bodies so direction is well-defined.
            dx = CGFloat(i - j) * 0.001 + 0.001
            dy = CGFloat(j - i) * 0.001 + 0.001
            distSq = max(dx * dx + dy * dy, 0.01)
        }
        let dist = sqrt(distSq)
        let force = repulsionStrength / distSq
        fx[i] += (dx / dist) * force
        fy[i] += (dy / dist) * force

        let minDist = radii[i] + radii[j] + 4
        if dist < minDist {
            let push = (minDist - dist) * 0.25
            sx[i] += (dx / dist) * push
            sy[i] += (dy / dist) * push
        }
    }

    func reheat() {
        isSettled = false
        iterationCount = 0
        for id in nodeOrder {
            guard var node = nodes[id], !node.pinned else { continue }
            node.velocity.dx += CGFloat.random(in: -1.5...1.5)
            node.velocity.dy += CGFloat.random(in: -1.5...1.5)
            nodes[id] = node
        }
    }

    func position(for id: UUID) -> CGPoint? { nodes[id]?.position }

    func radius(for id: UUID) -> CGFloat? { nodes[id]?.radius }

    func nearestNode(to world: CGPoint, scale: CGFloat, slop: CGFloat) -> UUID? {
        var best: (id: UUID, distSq: CGFloat)?
        for (id, node) in nodes {
            let dx = world.x - node.position.x
            let dy = world.y - node.position.y
            let distSq = dx * dx + dy * dy
            let touch = node.radius * scale + slop
            guard distSq <= touch * touch else { continue }
            if best == nil || distSq < best!.distSq {
                best = (id, distSq)
            }
        }
        return best?.id
    }

    func setPinned(_ pinned: Bool, for id: UUID) {
        guard var node = nodes[id] else { return }
        node.pinned = pinned
        if pinned { node.velocity = .zero }
        nodes[id] = node
    }

    func move(id: UUID, to position: CGPoint) {
        guard var node = nodes[id] else { return }
        node.position = position
        node.velocity = .zero
        nodes[id] = node
        isSettled = false
        iterationCount = 0
        publishSnapshot()
    }

    func nudge() {
        isSettled = false
        iterationCount = max(iterationCount - 200, 0)
    }

    func prewarm(maxSteps: Int) {
        var steps = 0
        while !isSettled && steps < maxSteps {
            step()
            steps += 1
        }
    }

    private static func radius(for weight: Int) -> CGFloat {
        let clamped = max(0, min(weight, 36))
        return 5 + sqrt(CGFloat(clamped)) * 2.5
    }

    fileprivate static func typeWeight(for type: BlockType) -> CGFloat {
        switch type {
        case .moc:        return 1.2
        case .project:    return 1.3
        case .permanent:  return 1.0
        case .literature: return 0.95
        case .fleeting:   return 0.85
        }
    }

    private static func seedPosition(index: Int, total: Int, canvas: CGFloat) -> CGPoint {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let radius = (Double(index) / Double(max(total, 1))).squareRoot() * Double(canvas) * 0.42
        let theta = Double(index) * golden
        return CGPoint(x: CGFloat(Foundation.cos(theta)) * CGFloat(radius), y: CGFloat(Foundation.sin(theta)) * CGFloat(radius))
    }
}

struct ScrollWheelMonitor: NSViewRepresentable {
    let isActiveCheck: () -> Bool
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onScroll = onScroll
        view.isActiveCheck = isActiveCheck
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onScroll = onScroll
        (nsView as? MonitorView)?.isActiveCheck = isActiveCheck
    }

    final class MonitorView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        var isActiveCheck: (() -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                guard self.isActiveCheck?() ?? true else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.0035 : event.scrollingDeltaY * 0.05
                self.onScroll?(delta)
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct MouseEventMonitor: NSViewRepresentable {
    let isActiveCheck: () -> Bool
    let onDown: (CGPoint) -> Void
    let onDrag: (CGPoint) -> Void
    let onUp: (CGPoint) -> Void
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> MouseNSView {
        let v = MouseNSView()
        v.callbacks = .init(down: onDown, drag: onDrag, up: onUp, move: onMove, exit: onExit)
        v.isActiveCheck = isActiveCheck
        return v
    }

    func updateNSView(_ nsView: MouseNSView, context: Context) {
        nsView.callbacks = .init(down: onDown, drag: onDrag, up: onUp, move: onMove, exit: onExit)
        nsView.isActiveCheck = isActiveCheck
    }

    @MainActor
    final class MouseNSView: NSView {
        struct Callbacks {
            let down: (CGPoint) -> Void
            let drag: (CGPoint) -> Void
            let up: (CGPoint) -> Void
            let move: (CGPoint) -> Void
            let exit: () -> Void
        }
        var callbacks: Callbacks?
        var isActiveCheck: (() -> Bool)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            (isActiveCheck?() ?? true) ? super.hitTest(point) : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeInActiveApp, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseDown(with event: NSEvent) {
            callbacks?.down(convert(event.locationInWindow, from: nil))
        }
        override func mouseDragged(with event: NSEvent) {
            callbacks?.drag(convert(event.locationInWindow, from: nil))
        }
        override func mouseUp(with event: NSEvent) {
            callbacks?.up(convert(event.locationInWindow, from: nil))
        }
        override func mouseMoved(with event: NSEvent) {
            callbacks?.move(convert(event.locationInWindow, from: nil))
        }
        override func mouseEntered(with event: NSEvent) {
            callbacks?.move(convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) {
            callbacks?.exit()
        }
    }
}

struct GraphViewport: Codable {
    var zoom: Double = 1.0
    var panX: Double = 0
    var panY: Double = 0
}
