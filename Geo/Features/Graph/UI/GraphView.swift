import AppKit
import SwiftUI

struct GraphSimulationParams {
    var centerStrength: CGFloat = 0.0008
    var repulsionStrength: CGFloat = 18000
    var springStiffness: CGFloat = 0.012
    var springLength: CGFloat = 220
    var groupAttraction: CGFloat = 0.0
}

enum GraphColorMode: String, Codable, CaseIterable {
    case tag
    case type
    case layer
}

struct GraphSettings: Equatable, Codable {
    var searchText: String = ""
    var showOrphans: Bool = true
    var showUnresolved: Bool = true
    var useColor: Bool = true
    var colorBy: GraphColorMode = .tag
    var showLabels: Bool = true
    var textFadeThreshold: Double = 0.6
    var nodeSizeScale: Double = 1.3
    var lineThickness: Double = 1.0
    var centerForce: Double = 0.0008
    var repelForce: Double = 18000
    var linkForce: Double = 0.012
    var linkDistance: Double = 220
    var groupAttraction: Double = 0.0
    var hiddenGroups: Set<String> = []
    var zoom: Double = 1.0
    var panX: Double = 0
    var panY: Double = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case searchText, showOrphans, showUnresolved, useColor, colorBy, showLabels
        case textFadeThreshold, nodeSizeScale, lineThickness
        case centerForce, repelForce, linkForce, linkDistance, groupAttraction
        case hiddenGroups, zoom, panX, panY
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.searchText = try c.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        self.showOrphans = try c.decodeIfPresent(Bool.self, forKey: .showOrphans) ?? true
        self.showUnresolved = try c.decodeIfPresent(Bool.self, forKey: .showUnresolved) ?? true
        self.useColor = try c.decodeIfPresent(Bool.self, forKey: .useColor) ?? true
        self.colorBy = try c.decodeIfPresent(GraphColorMode.self, forKey: .colorBy) ?? .tag
        self.showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        self.textFadeThreshold = try c.decodeIfPresent(Double.self, forKey: .textFadeThreshold) ?? 0.6
        self.nodeSizeScale = try c.decodeIfPresent(Double.self, forKey: .nodeSizeScale) ?? 1.3
        self.lineThickness = try c.decodeIfPresent(Double.self, forKey: .lineThickness) ?? 1.0
        self.centerForce = try c.decodeIfPresent(Double.self, forKey: .centerForce) ?? 0.0008
        self.repelForce = try c.decodeIfPresent(Double.self, forKey: .repelForce) ?? 18000
        self.linkForce = try c.decodeIfPresent(Double.self, forKey: .linkForce) ?? 0.012
        self.linkDistance = try c.decodeIfPresent(Double.self, forKey: .linkDistance) ?? 220
        self.groupAttraction = try c.decodeIfPresent(Double.self, forKey: .groupAttraction) ?? 0.0
        self.hiddenGroups = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenGroups) ?? []
        self.zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? 1.0
        self.panX = try c.decodeIfPresent(Double.self, forKey: .panX) ?? 0
        self.panY = try c.decodeIfPresent(Double.self, forKey: .panY) ?? 0
    }
}

private struct GraphPhysicsNode {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var pinned: Bool
}

private struct GraphLayout {
    var positions: [UUID: CGPoint]
    var radii: [UUID: CGFloat]
}

private struct EdgeKey: Hashable {
    let source: UUID
    let target: UUID
}

private final class GraphSimulation: ObservableObject {
    @Published private(set) var layout = GraphLayout(positions: [:], radii: [:])
    @Published private(set) var isSettled = false

    private var nodes: [UUID: GraphPhysicsNode] = [:]
    private var adjacency: [(UUID, UUID, Bool)] = []
    private var nodeOrder: [UUID] = []
    private var virtualTargets: [UUID: CGPoint] = [:]
    private var groupKey: [UUID: String] = [:]

    var params = GraphSimulationParams()

    private let damping: CGFloat = 0.86
    private let maxVelocity: CGFloat = 14
    private let kineticThreshold: CGFloat = 0.018
    private let timeStep: CGFloat = 0.85
    private var iterationCount = 0
    private let maxIterations = 1400
    private var quietStreak = 0
    private let quietStreakThreshold = 6

    func seedCachedPositions(_ positions: [UUID: CGPoint], settled: Bool) {
        for (id, pos) in positions where nodes[id] == nil {
            nodes[id] = GraphPhysicsNode(position: pos, velocity: .zero, radius: 8, pinned: false)
        }
        if settled { isSettled = true }
    }

    func ingest(graph: BlockGraph) {
        let canvasSize: CGFloat = 720
        var newNodes: [UUID: GraphPhysicsNode] = [:]
        var newOrder: [UUID] = []
        var newGroupKey: [UUID: String] = [:]
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
            if let color = node.tagColor {
                newGroupKey[node.id] = Self.colorKey(color)
            }
        }
        var resolvedEdges: [(UUID, UUID, Bool)] = []
        var virtuals: [UUID: CGPoint] = [:]
        for edge in graph.edges {
            if let target = edge.targetId, newNodes[target] != nil, newNodes[edge.sourceId] != nil {
                resolvedEdges.append((edge.sourceId, target, true))
            } else if let source = newNodes[edge.sourceId] {
                let virtualID = edge.id
                let angle = Double(abs(edge.id.uuidString.hashValue) % 360) * .pi / 180
                let offset = CGVector(dx: CGFloat(Foundation.cos(angle)) * 90,
                                       dy: CGFloat(Foundation.sin(angle)) * 90)
                virtuals[virtualID] = CGPoint(x: source.position.x + offset.dx, y: source.position.y + offset.dy)
                resolvedEdges.append((edge.sourceId, virtualID, false))
            }
        }

        let newNodeIDs = Set(newOrder)
        let removedCount = priorNodeIDs.subtracting(newNodeIDs).count
        let nodeStructural = addedCount > 0 || removedCount > 0

        var priorResolvedEdges = Set<EdgeKey>()
        for (s, t, resolved) in adjacency where resolved {
            priorResolvedEdges.insert(EdgeKey(source: s, target: t))
        }
        var newResolvedEdges = Set<EdgeKey>()
        for (s, t, resolved) in resolvedEdges where resolved {
            newResolvedEdges.insert(EdgeKey(source: s, target: t))
        }
        let edgeStructural = priorResolvedEdges != newResolvedEdges
        let firstIngest = priorNodeIDs.isEmpty

        nodes = newNodes
        nodeOrder = newOrder
        adjacency = resolvedEdges
        virtualTargets = virtuals
        groupKey = newGroupKey

        if firstIngest || nodeStructural {
            isSettled = false
            iterationCount = 0
        } else if edgeStructural {
            isSettled = false
            iterationCount = max(iterationCount, maxIterations - 200)
        }
        publishLayout()
    }

    func step() {
        guard !isSettled, !nodes.isEmpty else { return }
        iterationCount += 1

        var forces: [UUID: CGVector] = [:]
        for id in nodeOrder { forces[id] = .zero }

        let maxRepelDistSq: CGFloat = 90000
        for i in 0..<nodeOrder.count {
            let aID = nodeOrder[i]
            guard let a = nodes[aID] else { continue }
            for j in (i + 1)..<nodeOrder.count {
                let bID = nodeOrder[j]
                guard let b = nodes[bID] else { continue }
                let dx = a.position.x - b.position.x
                let dy = a.position.y - b.position.y
                let distSq = max(dx * dx + dy * dy, 0.01)
                if distSq > maxRepelDistSq { continue }
                let dist = sqrt(distSq)
                let force = params.repulsionStrength / distSq
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[aID]?.dx += fx
                forces[aID]?.dy += fy
                forces[bID]?.dx -= fx
                forces[bID]?.dy -= fy
            }
        }

        for (sourceID, targetID, resolved) in adjacency {
            guard let source = nodes[sourceID] else { continue }
            let targetPos: CGPoint
            if resolved {
                guard let target = nodes[targetID] else { continue }
                targetPos = target.position
            } else {
                targetPos = virtualTargets[targetID] ?? source.position
            }
            let dx = targetPos.x - source.position.x
            let dy = targetPos.y - source.position.y
            let dist = max(sqrt(dx * dx + dy * dy), 0.01)
            let displacement = dist - params.springLength
            let fx = (dx / dist) * displacement * params.springStiffness
            let fy = (dy / dist) * displacement * params.springStiffness
            forces[sourceID]?.dx += fx
            forces[sourceID]?.dy += fy
            if resolved {
                forces[targetID]?.dx -= fx
                forces[targetID]?.dy -= fy
            } else {
                if var virtual = virtualTargets[targetID] {
                    virtual.x -= fx * 1.4
                    virtual.y -= fy * 1.4
                    virtualTargets[targetID] = virtual
                }
            }
        }

        for id in nodeOrder {
            guard let node = nodes[id] else { continue }
            forces[id]?.dx -= node.position.x * params.centerStrength
            forces[id]?.dy -= node.position.y * params.centerStrength
        }

        if params.groupAttraction > 0 && !groupKey.isEmpty {
            var sums: [String: (CGFloat, CGFloat, Int)] = [:]
            for (id, key) in groupKey {
                guard let node = nodes[id] else { continue }
                if let existing = sums[key] {
                    sums[key] = (existing.0 + node.position.x, existing.1 + node.position.y, existing.2 + 1)
                } else {
                    sums[key] = (node.position.x, node.position.y, 1)
                }
            }
            var centroids: [String: CGPoint] = [:]
            for (key, value) in sums where value.2 > 1 {
                centroids[key] = CGPoint(x: value.0 / CGFloat(value.2), y: value.1 / CGFloat(value.2))
            }
            for (id, key) in groupKey {
                guard let centroid = centroids[key], let node = nodes[id] else { continue }
                let dx = centroid.x - node.position.x
                let dy = centroid.y - node.position.y
                forces[id]?.dx += dx * params.groupAttraction
                forces[id]?.dy += dy * params.groupAttraction
            }
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
        publishLayout()
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
        publishLayout()
        isSettled = false
        iterationCount = 0
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

    private func publishLayout() {
        layout = GraphLayout(positions: nodes.mapValues(\.position), radii: nodes.mapValues(\.radius))
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

    fileprivate static func colorKey(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return String(format: "%.3f-%.3f-%.3f", ns.redComponent, ns.greenComponent, ns.blueComponent)
    }

    private static func seedPosition(index: Int, total: Int, canvas: CGFloat) -> CGPoint {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let radius = (Double(index) / Double(max(total, 1))).squareRoot() * Double(canvas) * 0.42
        let theta = Double(index) * golden
        return CGPoint(x: CGFloat(Foundation.cos(theta)) * CGFloat(radius), y: CGFloat(Foundation.sin(theta)) * CGFloat(radius))
    }
}

private struct ScrollWheelMonitor: NSViewRepresentable {
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

private struct MouseEventMonitor: NSViewRepresentable {
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

private struct GroupSwatch: Identifiable, Hashable {
    let id: String
    let color: Color
    let count: Int
}

struct GraphView: View {
    let graph: BlockGraph
    var seedPositions: [UUID: CGPoint] = [:]
    var wasSettled: Bool = false
    var externalChangeSignal: ExternalChangeSignal? = nil
    var sidebarHidden: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onLayoutChange: (([UUID: CGPoint], Bool) -> Void)? = nil
    var onNodeTap: (UUID) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tabRouter) private var tabRouter
    @StateObject private var simulation = GraphSimulation()
    @State private var externalPulses: [UUID: Date] = [:]
    @State private var removalPulses: [UUID: (position: CGPoint, radius: CGFloat, start: Date)] = [:]
    private static let pulseDuration: TimeInterval = 1.2
    private static let removalDuration: TimeInterval = 0.9

    @State private var zoom: CGFloat = CGFloat(GraphView.bootstrappedSettings().zoom)
    @State private var pendingZoom: CGFloat = CGFloat(GraphView.bootstrappedSettings().zoom)
    @State private var pan: CGSize = CGSize(width: GraphView.bootstrappedSettings().panX, height: GraphView.bootstrappedSettings().panY)
    @State private var pendingPan: CGSize = .zero
    @State private var hoverNodeID: UUID?
    @State private var draggingNodeID: UUID?
    @State private var selectedNodeID: UUID?
    @State private var canvasSize: CGSize = .zero
    @State private var hasFramedInitialLayout = false
    @State private var mouseDownPoint: CGPoint?
    @State private var mouseDownNodeID: UUID?

    @State private var settingsOpen: Bool = false
    @State private var zoomPersistTask: Task<Void, Never>?

    @State private var cachedVisibleSet: Set<UUID> = []
    @State private var cachedVisibleNodes: [GraphNode] = []
    @State private var cachedVisibleEdges: [GraphEdge] = []
    @State private var cachedFocusedID: UUID?
    @State private var cachedNeighbors: Set<UUID> = []

    private func scheduleZoomPersist(_ value: CGFloat) {
        zoomPersistTask?.cancel()
        zoomPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            settings.zoom = Double(value)
        }
    }

    @State private var settings: GraphSettings = GraphView.bootstrappedSettings()

    private var forcesTuple: [Double] { [settings.centerForce, settings.repelForce, settings.linkForce, settings.linkDistance, settings.groupAttraction] }

    var body: some View {
        GeometryReader { geo in
            stackedContent
                .onAppear {
                    onAppearActions(size: geo.size)
                }
                .onDisappear {
                    onLayoutChange?(simulation.layout.positions, simulation.isSettled)
                }
                .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
                .onChange(of: graph) { oldGraph, newGraph in handleGraphChange(from: oldGraph, to: newGraph) }
                .onChange(of: externalChangeSignal) { _, signal in handleExternalSignal(signal) }
                .onChange(of: simulation.isSettled) { _, settled in handleSettledChange(settled) }
                .onChange(of: forcesTuple) { _, _ in handleForcesChange() }
                .onChange(of: settings) { _, newSettings in Self.saveSettings(newSettings); recomputeVisibilityCache() }
                .onChange(of: hoverNodeID) { _, _ in recomputeFocusCache() }
                .onChange(of: selectedNodeID) { _, _ in recomputeFocusCache() }
                .onChange(of: settings.colorBy) { _, _ in settings.hiddenGroups.removeAll() }
        }
    }

    private func handleGraphChange(from oldGraph: BlockGraph, to newGraph: BlockGraph) {
        detectCRUDPulses(from: oldGraph, to: newGraph)
        simulation.ingest(graph: newGraph)
        let valid = Set(newGraph.nodes.map(\.id))
        if let sel = selectedNodeID, !valid.contains(sel) { selectedNodeID = nil }
        if let hov = hoverNodeID, !valid.contains(hov) { hoverNodeID = nil }
        if let drag = draggingNodeID, !valid.contains(drag) { draggingNodeID = nil }
        if !externalPulses.isEmpty {
            externalPulses = externalPulses.filter { valid.contains($0.key) }
        }
        recomputeVisibilityCache()
        frameInitialLayoutIfNeeded()
    }

    private func detectCRUDPulses(from oldGraph: BlockGraph, to newGraph: BlockGraph) {
        guard !oldGraph.nodes.isEmpty else { return }
        let oldIds = Set(oldGraph.nodes.map(\.id))
        let newIds = Set(newGraph.nodes.map(\.id))
        let added = newIds.subtracting(oldIds)
        let removed = oldIds.subtracting(newIds)

        let oldNode = Dictionary(oldGraph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newNode = Dictionary(newGraph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldSig = incidentSignatures(oldGraph)
        let newSig = incidentSignatures(newGraph)
        var updated = Set<UUID>()
        for id in newIds.intersection(oldIds) where oldNode[id] != newNode[id] || oldSig[id] != newSig[id] {
            updated.insert(id)
        }

        let churn = added.count + removed.count + updated.count
        guard churn > 0, churn <= max(8, newGraph.nodes.count / 4) else { return }

        let now = Date()
        let pulseTargets = added.union(updated)
        if !pulseTargets.isEmpty {
            var merged = externalPulses.filter { now.timeIntervalSince($0.value) < Self.pulseDuration }
            for id in pulseTargets { merged[id] = now }
            externalPulses = merged
        }
        if !removed.isEmpty {
            var ghosts = removalPulses.filter { now.timeIntervalSince($0.value.start) < Self.removalDuration }
            for id in removed {
                guard let pos = simulation.position(for: id) else { continue }
                ghosts[id] = (pos, simulation.radius(for: id) ?? 8, now)
            }
            removalPulses = ghosts
        }
        simulation.nudge()
    }

    private func incidentSignatures(_ graph: BlockGraph) -> [UUID: Set<String>] {
        var sig: [UUID: Set<String>] = [:]
        for edge in graph.edges {
            if let target = edge.targetId {
                sig[edge.sourceId, default: []].insert("o:\(target.uuidString)")
                sig[target, default: []].insert("i:\(edge.sourceId.uuidString)")
            } else {
                sig[edge.sourceId, default: []].insert("u:\(edge.targetTitle)")
            }
        }
        return sig
    }

    private func pruneEffects(now: Date) {
        if !externalPulses.isEmpty {
            let kept = externalPulses.filter { now.timeIntervalSince($0.value) < Self.pulseDuration }
            if kept.count != externalPulses.count { externalPulses = kept }
        }
        if !removalPulses.isEmpty {
            let kept = removalPulses.filter { now.timeIntervalSince($0.value.start) < Self.removalDuration }
            if kept.count != removalPulses.count { removalPulses = kept }
        }
    }

    private var hasActiveEffects: Bool { !externalPulses.isEmpty || !removalPulses.isEmpty }

    private func recomputeVisibilityCache() {
        let set = computeVisibleNodeIDs()
        cachedVisibleSet = set
        cachedVisibleNodes = graph.nodes.filter { set.contains($0.id) }
        cachedVisibleEdges = graph.edges.filter { edge in
            guard set.contains(edge.sourceId) else { return false }
            if let target = edge.targetId, !set.contains(target) { return false }
            return true
        }
        recomputeFocusCache()
    }

    private func recomputeFocusCache() {
        let focused = hoverNodeID ?? selectedNodeID
        cachedFocusedID = focused
        cachedNeighbors = focused.map(neighborSet) ?? []
    }

    private func handleExternalSignal(_ signal: ExternalChangeSignal?) {
        guard let signal else { return }
        let now = signal.timestamp
        var updated: [UUID: Date] = [:]
        for (id, start) in externalPulses where now.timeIntervalSince(start) < Self.pulseDuration {
            updated[id] = start
        }
        for id in signal.nodeIds {
            updated[id] = now
        }
        externalPulses = updated
        simulation.nudge()
    }

    private func handleSettledChange(_ settled: Bool) {
        if settled {
            onLayoutChange?(simulation.layout.positions, true)
        }
    }

    private func handleForcesChange() {
        applyForcesToSimulation()
        simulation.reheat()
    }

    private var stackedContent: some View {
        ZStack(alignment: .topTrailing) {
            backgroundLayer
            simulationCanvas
            labelOverlay
            gestureLayer
            scrollWheelLayer
            sidebarToggle
            settingsToggle
            settingsDrawer
        }
    }

    @ViewBuilder
    private var sidebarToggle: some View {
        if let onToggleSidebar {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.foreground.opacity(0.85))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.secondaryBackground.opacity(0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Palette.border.opacity(0.5), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .help(sidebarHidden ? "Show list" : "Hide list")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 12)
            .padding(.leading, 12)
            .zIndex(10)
        }
    }

    private var gestureLayer: some View {
        MouseEventMonitor(
            isActiveCheck: { [tabRouter] in tabRouter.selectedTab == .nodes },
            onDown: handleMouseDown,
            onDrag: handleMouseDrag,
            onUp: handleMouseUp,
            onMove: { hoverNodeID = nodeHit(at: $0) },
            onExit: { hoverNodeID = nil }
        )
        .gesture(magnificationGesture)
    }

    private func handleMouseDown(at point: CGPoint) {
        mouseDownPoint = point
        mouseDownNodeID = nodeHit(at: point)
    }

    private func handleMouseDrag(to point: CGPoint) {
        guard let start = mouseDownPoint else { return }
        let dx = point.x - start.x
        let dy = point.y - start.y
        if draggingNodeID == nil, let candidate = mouseDownNodeID, dx * dx + dy * dy >= 16 {
            draggingNodeID = candidate
            simulation.setPinned(true, for: candidate)
        }
        if let id = draggingNodeID {
            simulation.move(id: id, to: unprojected(point))
        } else if mouseDownNodeID == nil {
            pendingPan = CGSize(width: dx, height: dy)
        }
    }

    private func handleMouseUp(at point: CGPoint) {
        defer {
            mouseDownPoint = nil
            mouseDownNodeID = nil
        }
        guard let start = mouseDownPoint else { return }
        if let id = draggingNodeID {
            simulation.setPinned(false, for: id)
            draggingNodeID = nil
            simulation.nudge()
            return
        }
        let dx = point.x - start.x
        let dy = point.y - start.y
        if dx * dx + dy * dy < 16 {
            handleTap(at: point)
            pendingPan = .zero
        } else if mouseDownNodeID == nil {
            pan.width += dx
            pan.height += dy
            pendingPan = .zero
            settings.panX = Double(pan.width)
            settings.panY = Double(pan.height)
        }
    }

    private var simulationCanvas: some View {
        TimelineView(.animation(paused: simulation.isSettled && draggingNodeID == nil && !hasActiveEffects)) { context in
            Canvas(rendersAsynchronously: true) { canvasContext, size in
                renderCanvas(canvasContext: canvasContext, size: size)
            }
            .onChange(of: context.date) { _, date in
                DispatchQueue.main.async {
                    simulation.step()
                    pruneEffects(now: date)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var scrollWheelLayer: some View {
        ScrollWheelMonitor(isActiveCheck: { [tabRouter] in tabRouter.selectedTab == .nodes }) { delta in
            let next = max(0.4, min(2.4, zoom * (1 + delta)))
            zoom = next
            pendingZoom = next
            scheduleZoomPersist(next)
        }
        .allowsHitTesting(false)
    }

    private func onAppearActions(size: CGSize) {
        canvasSize = size
        applyForcesToSimulation()
        if !seedPositions.isEmpty {
            simulation.seedCachedPositions(seedPositions, settled: wasSettled)
        }
        simulation.ingest(graph: graph)
        recomputeVisibilityCache()
        frameInitialLayoutIfNeeded()
    }

    private func frameInitialLayoutIfNeeded() {
        guard !hasFramedInitialLayout,
              seedPositions.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0,
              !simulation.layout.positions.isEmpty else { return }
        hasFramedInitialLayout = true
        let size = canvasSize
        DispatchQueue.main.async {
            simulation.prewarm(maxSteps: 480)
            fitToView(in: size)
        }
    }

    private func fitToView(in size: CGSize) {
        let positions = simulation.layout.positions
        guard !positions.isEmpty else { return }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for (id, p) in positions {
            let r = (simulation.layout.radii[id] ?? 8) * CGFloat(settings.nodeSizeScale)
            minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
            minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
        }
        let bboxW = max(maxX - minX, 1), bboxH = max(maxY - minY, 1)
        let fit = min(size.width / bboxW, size.height / bboxH) * 0.85
        let newZoom = max(0.4, min(2.4, fit))
        zoom = newZoom
        pendingZoom = newZoom
        pan = CGSize(width: -(minX + maxX) / 2 * newZoom, height: -(minY + maxY) / 2 * newZoom)
        pendingPan = .zero
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.06) : Color.white
    }

    private var backgroundLayer: some View {
        backgroundColor.ignoresSafeArea()
    }

    private var settingsToggle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                settingsOpen.toggle()
            }
        } label: {
            Image(systemName: settingsOpen ? "xmark" : "slider.horizontal.3")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.foreground.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.secondaryBackground.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Palette.border.opacity(0.5), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .padding(.trailing, 12)
        .zIndex(10)
    }

    @ViewBuilder
    private var settingsDrawer: some View {
        if settingsOpen {
            SettingsPanel(
                settings: $settings,
                groups: groupSwatches
            )
            .frame(width: 260)
            .padding(.top, 52)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(9)
        }
    }

    private var groupSwatches: [GroupSwatch] {
        var buckets: [String: (Color, Int)] = [:]
        for node in graph.nodes {
            let key: String
            let color: Color
            switch settings.colorBy {
            case .tag:
                guard let c = node.tagColor else { continue }
                key = colorKey(c)
                color = c
            case .type:
                key = node.type.rawValue
                color = GraphView.defaultColor(for: node.type)
            case .layer:
                key = node.layer.rawValue
                color = GraphView.defaultColor(for: node.layer)
            }
            buckets[key, default: (color, 0)].1 += 1
        }
        return buckets
            .map { GroupSwatch(id: $0.key, color: $0.value.0, count: $0.value.1) }
            .sorted { $0.count > $1.count }
    }

    private func colorKey(_ color: Color) -> String {
        GraphSimulation.colorKey(color)
    }

    fileprivate static func defaultColor(for type: BlockType) -> Color {
        switch type {
        case .fleeting:   return Color(white: 0.55)
        case .literature: return Color(red: 0.40, green: 0.60, blue: 0.70)
        case .permanent:  return Color(red: 0.30, green: 0.65, blue: 0.45)
        case .moc:        return Color(red: 0.55, green: 0.40, blue: 0.75)
        case .project:    return Color(red: 0.85, green: 0.50, blue: 0.30)
        }
    }

    fileprivate static func defaultColor(for layer: BlockLayer) -> Color {
        switch layer {
        case .user:   return Color(red: 0.16, green: 0.52, blue: 0.86)
        case .agent:  return Color(red: 0.62, green: 0.42, blue: 0.78)
        case .review: return Color(red: 0.90, green: 0.62, blue: 0.18)
        case .shared: return Color(red: 0.24, green: 0.66, blue: 0.48)
        }
    }

    private static let settingsKey = "geo.graphSettings.v2"

    private static func saveSettings(_ s: GraphSettings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private static func bootstrappedSettings() -> GraphSettings {
        let data = UserDefaults.standard.data(forKey: settingsKey)
        var s = (data.flatMap { try? JSONDecoder().decode(GraphSettings.self, from: $0) }) ?? GraphSettings()
        s.zoom = min(max(s.zoom, 0.4), 2.4)
        s.panX = min(max(s.panX, -5000), 5000)
        s.panY = min(max(s.panY, -5000), 5000)
        return s
    }

    private func applyForcesToSimulation() {
        simulation.params = GraphSimulationParams(
            centerStrength: CGFloat(settings.centerForce),
            repulsionStrength: CGFloat(settings.repelForce),
            springStiffness: CGFloat(settings.linkForce),
            springLength: CGFloat(settings.linkDistance),
            groupAttraction: CGFloat(settings.groupAttraction)
        )
    }

    private func neighborSet(of id: UUID) -> Set<UUID> {
        var set: Set<UUID> = [id]
        for edge in graph.edges {
            if edge.sourceId == id, let target = edge.targetId {
                set.insert(target)
            } else if edge.targetId == id {
                set.insert(edge.sourceId)
            }
        }
        return set
    }

    private func computeVisibleNodeIDs() -> Set<UUID> {
        var connected: Set<UUID> = []
        if !settings.showOrphans {
            for edge in graph.edges {
                connected.insert(edge.sourceId)
                if let t = edge.targetId { connected.insert(t) }
            }
        }
        var ids = Set<UUID>()
        for node in graph.nodes {
            if !settings.searchText.isEmpty,
               !node.title.localizedCaseInsensitiveContains(settings.searchText) { continue }
            switch settings.colorBy {
            case .tag:
                if let color = node.tagColor, settings.hiddenGroups.contains(colorKey(color)) { continue }
            case .type:
                if settings.hiddenGroups.contains(node.type.rawValue) { continue }
            case .layer:
                if settings.hiddenGroups.contains(node.layer.rawValue) { continue }
            }
            if !settings.showOrphans, !connected.contains(node.id) { continue }
            ids.insert(node.id)
        }
        return ids
    }

    private var labelOverlay: some View {
        let focused = cachedFocusedID
        let neighbors = cachedNeighbors
        return ZStack(alignment: .topLeading) {
            if settings.showLabels {
                ForEach(cachedVisibleNodes, id: \.id) { node in
                    let position = projected(simulation.position(for: node.id) ?? .zero)
                    let isFocused = focused == node.id
                    let isNeighbor = neighbors.contains(node.id)
                    let opacity = labelOpacity(for: node, focused: focused, isNeighbor: isNeighbor)
                    Text(node.title)
                        .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                        .foregroundStyle(Color(white: colorScheme == .dark ? 0.7 : 0.3).opacity(opacity))
                        .fixedSize()
                        .position(x: position.x, y: position.y + (simulation.radius(for: node.id) ?? 8) * CGFloat(settings.nodeSizeScale) * effectiveZoom + 9)
                        .opacity(opacity)
                        .animation(.easeInOut(duration: 0.15), value: focused)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func labelOpacity(for node: GraphNode, focused: UUID?, isNeighbor: Bool) -> Double {
        if focused == node.id { return 1.0 }
        let zoomFactor: Double
        if effectiveZoom >= CGFloat(settings.textFadeThreshold) {
            zoomFactor = 1.0
        } else {
            let weightBoost = min(1.0, Double(node.weight) / 12.0)
            zoomFactor = max(0.0, weightBoost - (Double(settings.textFadeThreshold) - Double(effectiveZoom)))
        }
        if let focused, focused != node.id {
            if isNeighbor {
                return min(1.0, 0.85 * zoomFactor)
            }
            return 0.15 * zoomFactor
        }
        return zoomFactor * 0.85
    }

    private var effectiveZoom: CGFloat { pendingZoom }
    private var effectivePan: CGSize { CGSize(width: pan.width + pendingPan.width, height: pan.height + pendingPan.height) }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pendingZoom = max(0.4, min(2.4, zoom * value))
            }
            .onEnded { value in
                zoom = max(0.4, min(2.4, zoom * value))
                pendingZoom = zoom
                settings.zoom = Double(zoom)
            }
    }

    private func handleTap(at location: CGPoint) {
        if let hit = nodeHit(at: location) {
            selectedNodeID = hit
            onNodeTap(hit)
        } else {
            selectedNodeID = nil
        }
    }

    private func nodeHit(at viewPoint: CGPoint) -> UUID? {
        let world = unprojected(viewPoint)
        let visibleSet = cachedVisibleSet
        var best: (UUID, CGFloat)?
        for node in graph.nodes where visibleSet.contains(node.id) {
            guard let pos = simulation.position(for: node.id), let radius = simulation.radius(for: node.id) else { continue }
            let dx = world.x - pos.x
            let dy = world.y - pos.y
            let distSq = dx * dx + dy * dy
            let touch = radius * CGFloat(settings.nodeSizeScale) + 4
            if distSq <= touch * touch {
                if best == nil || distSq < best!.1 {
                    best = (node.id, distSq)
                }
            }
        }
        return best?.0
    }

    private func projected(_ world: CGPoint) -> CGPoint {
        let centerX = canvasSize.width / 2 + effectivePan.width
        let centerY = canvasSize.height / 2 + effectivePan.height
        return CGPoint(x: centerX + world.x * effectiveZoom, y: centerY + world.y * effectiveZoom)
    }

    private func unprojected(_ view: CGPoint) -> CGPoint {
        let centerX = canvasSize.width / 2 + effectivePan.width
        let centerY = canvasSize.height / 2 + effectivePan.height
        return CGPoint(x: (view.x - centerX) / max(effectiveZoom, 0.01), y: (view.y - centerY) / max(effectiveZoom, 0.01))
    }

    private func renderCanvas(canvasContext: GraphicsContext, size: CGSize) {
        var ctx = canvasContext
        let focused = cachedFocusedID
        let neighbors = cachedNeighbors
        let dimEverythingElse = focused != nil

        let neutralGrey = Color(white: 0.55)
        let edgeBaseColor = Color(white: 0.5)

        for edge in cachedVisibleEdges {
            if edge.targetId == nil && !settings.showUnresolved { continue }
            guard let sourcePos = simulation.position(for: edge.sourceId) else { continue }
            let sourceView = projected(sourcePos)
            let resolved = edge.targetId.flatMap { simulation.position(for: $0) }
            let targetView: CGPoint
            let isResolved: Bool
            if let resolved {
                targetView = projected(resolved)
                isResolved = true
            } else {
                let seed = Double(abs(edge.id.uuidString.hashValue) % 360) * .pi / 180
                let length: CGFloat = 70
                let virtualWorld = CGPoint(x: sourcePos.x + CGFloat(Foundation.cos(seed)) * length, y: sourcePos.y + CGFloat(Foundation.sin(seed)) * length)
                targetView = projected(virtualWorld)
                isResolved = false
            }

            let edgeTouchesFocus: Bool = {
                guard dimEverythingElse else { return false }
                if neighbors.contains(edge.sourceId) {
                    if let target = edge.targetId { return neighbors.contains(target) }
                    return neighbors.contains(edge.sourceId)
                }
                return false
            }()

            let baseOpacity: Double = isResolved ? 0.35 : 0.18
            let opacity: Double
            if dimEverythingElse {
                opacity = edgeTouchesFocus ? (isResolved ? 1.0 : 0.55) : 0.08
            } else {
                opacity = baseOpacity
            }

            var path = Path()
            path.move(to: sourceView)
            path.addLine(to: targetView)
            let strokeColor = edgeBaseColor.opacity(opacity)
            let width = 0.5 * settings.lineThickness
            if isResolved {
                ctx.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: width, lineCap: .round))
            } else {
                ctx.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [2, 3]))
            }
        }

        let renderNow = Date()
        for node in cachedVisibleNodes {
            guard let worldPos = simulation.position(for: node.id), let radius = simulation.radius(for: node.id) else { continue }
            let center = projected(worldPos)
            let scaledRadius = radius * CGFloat(settings.nodeSizeScale) * effectiveZoom
            let isFocused = focused == node.id
            let isNeighbor = neighbors.contains(node.id)

            let baseColor: Color
            if settings.useColor {
                switch settings.colorBy {
                case .tag:  baseColor = node.tagColor ?? neutralGrey
                case .type: baseColor = GraphView.defaultColor(for: node.type)
                case .layer: baseColor = GraphView.defaultColor(for: node.layer)
                }
            } else {
                baseColor = neutralGrey
            }

            let alpha: Double
            if dimEverythingElse {
                if isFocused { alpha = 1.0 }
                else if isNeighbor { alpha = 1.0 }
                else { alpha = 0.15 }
            } else {
                alpha = 1.0
            }

            if let pulseStart = externalPulses[node.id] {
                let elapsed = renderNow.timeIntervalSince(pulseStart)
                if elapsed >= 0, elapsed < Self.pulseDuration {
                    let t = elapsed / Self.pulseDuration
                    let eased = 1 - (1 - t) * (1 - t)
                    let pulseRadius = scaledRadius + 4 + CGFloat(eased) * 18
                    let pulseAlpha = (1 - t) * 0.55
                    let pulseRect = CGRect(x: center.x - pulseRadius, y: center.y - pulseRadius, width: pulseRadius * 2, height: pulseRadius * 2)
                    ctx.stroke(Path(ellipseIn: pulseRect), with: .color(baseColor.opacity(pulseAlpha)), lineWidth: 1.5)
                }
            }

            let bodyRect = CGRect(x: center.x - scaledRadius, y: center.y - scaledRadius, width: scaledRadius * 2, height: scaledRadius * 2)
            ctx.fill(Path(ellipseIn: bodyRect), with: .color(baseColor.opacity(alpha)))

            if isFocused {
                let ringRect = bodyRect.insetBy(dx: -2.5, dy: -2.5)
                ctx.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(baseColor.opacity(alpha * 0.55)),
                    lineWidth: 1.0
                )
            } else {
                ctx.stroke(
                    Path(ellipseIn: bodyRect),
                    with: .color(Color(white: 0.0).opacity(alpha * 0.15)),
                    lineWidth: 0.3
                )
            }
        }
    }
}

private struct SettingsPanel: View {
    @Binding var settings: GraphSettings
    let groups: [GroupSwatch]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section(title: "Filters") {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.tertiaryForeground)
                        TextField("Search", text: $settings.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.foreground)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Palette.background.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Palette.border.opacity(0.45), lineWidth: 0.5)
                    )

                    toggleRow(label: "Show orphans", binding: $settings.showOrphans)
                    toggleRow(label: "Show unresolved", binding: $settings.showUnresolved)
                }

                section(title: "Display") {
                    HStack {
                        Text("Color by")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.foreground.opacity(0.92))
                        Spacer()
                        Picker("Color by", selection: $settings.colorBy) {
                            Text("Tag").tag(GraphColorMode.tag)
                            Text("Type").tag(GraphColorMode.type)
                            Text("Camada").tag(GraphColorMode.layer)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .labelsHidden()
                        .frame(width: 178)
                    }
                    toggleRow(label: "Use color", binding: $settings.useColor)
                    toggleRow(label: "Show labels", binding: $settings.showLabels)
                    sliderRow(label: "Text fade threshold", value: $settings.textFadeThreshold, range: 0...1, format: "%.2f")
                    sliderRow(label: "Node size scale", value: $settings.nodeSizeScale, range: 0.5...2.5, format: "%.2f")
                    sliderRow(label: "Line thickness", value: $settings.lineThickness, range: 0.5...2.5, format: "%.2f")
                }

                section(title: "Forces") {
                    sliderRow(label: "Center force", value: $settings.centerForce, range: 0...0.005, format: "%.4f")
                    sliderRow(label: "Repel force", value: $settings.repelForce, range: 2000...40000, format: "%.0f")
                    sliderRow(label: "Link force", value: $settings.linkForce, range: 0.001...0.04, format: "%.3f")
                    sliderRow(label: "Link distance", value: $settings.linkDistance, range: 60...300, format: "%.0f")
                    sliderRow(label: "Group attraction", value: $settings.groupAttraction, range: 0...0.05, format: "%.3f")
                }

                if !groups.isEmpty {
                    section(title: "Groups") {
                        ForEach(groups) { group in
                            groupRow(group: group)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.secondaryBackground.opacity(0.92))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Palette.border.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 6)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Palette.tertiaryForeground)
            content()
        }
    }

    private func toggleRow(label: String, binding: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.foreground.opacity(0.92))
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground.opacity(0.92))
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.tertiaryForeground)
            }
            Slider(value: value, in: range)
                .controlSize(.mini)
        }
    }

    private func groupRow(group: GroupSwatch) -> some View {
        let isHidden = settings.hiddenGroups.contains(group.id)
        let typeForRow: BlockType? = {
            guard settings.colorBy == .type else { return nil }
            return BlockType(rawValue: group.id)
        }()
        let layerForRow: BlockLayer? = {
            guard settings.colorBy == .layer else { return nil }
            return BlockLayer(rawValue: group.id)
        }()
        return HStack(spacing: 8) {
            if let type = typeForRow {
                Image(systemName: type.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(group.color)
                    .frame(width: 14, height: 14)
                Text("\(type.displayName) · \(group.count) nodes")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground.opacity(0.9))
            } else if let layer = layerForRow {
                Image(systemName: layer.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(group.color)
                    .frame(width: 14, height: 14)
                Text("\(layer.displayName) · \(group.count) nodes")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground.opacity(0.9))
            } else {
                Circle()
                    .fill(group.color)
                    .frame(width: 10, height: 10)
                Text("\(group.count) nodes")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground.opacity(0.9))
            }
            Spacer()
            Button {
                if isHidden {
                    settings.hiddenGroups.remove(group.id)
                } else {
                    settings.hiddenGroups.insert(group.id)
                }
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiaryForeground)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview("GraphView - Knowledge Graph") {

    let clusters: [(name: String, color: Color, type: BlockType, titles: [String])] = [
        ("Engineering", Color(red: 0.33, green: 0.61, blue: 0.96), .project, [
            "Force-Directed Layout", "Canvas Rendering", "Barnes-Hut", "Quadtree Optimization",
            "Spring Physics", "Damping Heuristics", "Frame Pacing", "Hot Reload",
            "GPU Compositor", "Render Pipeline", "Allocator Notes"
        ]),
        ("Product", Color(red: 0.96, green: 0.44, blue: 0.40), .moc, [
            "Roadmap Q3", "Pricing v2", "Activation Funnel", "Onboarding Flow",
            "Retention Loop", "Feature Audit", "User Interviews", "North Star Metric"
        ]),
        ("Research", Color(red: 0.42, green: 0.77, blue: 0.43), .permanent, [
            "Bidirectional Links", "Zettelkasten", "Bullet Journal", "Spaced Repetition",
            "Knowledge Graphs", "Note Atomicity", "Evergreen Notes", "PARA Method"
        ]),
        ("Personal", Color(red: 0.78, green: 0.47, blue: 0.87), .literature, [
            "Morning Pages", "Climbing Log", "Reading List", "Cooking Notes",
            "Travel Journal", "Sleep Patterns", "Weekly Review"
        ]),
        ("Writing", Color(red: 0.95, green: 0.75, blue: 0.30), .fleeting, [
            "Essay Drafts", "Newsletter Issue 12", "Talk Outline", "Book Notes",
            "Quote Vault", "Inbox", "Drafts/2026"
        ])
    ]

    var nodes: [GraphNode] = []
    var idsByCluster: [[UUID]] = []
    for cluster in clusters {
        var clusterIDs: [UUID] = []
        for title in cluster.titles {
            let weight = Int.random(in: 1...18)
            let node = GraphNode(id: UUID(), title: title, tagColor: cluster.color, type: cluster.type, layer: .user, weight: weight)
            nodes.append(node)
            clusterIDs.append(node.id)
        }
        idsByCluster.append(clusterIDs)
    }

    let neutralTitles = ["Untitled", "Scratch", "Draft 2026-04-25", "Loose Idea", "Random"]
    var neutralIDs: [UUID] = []
    for title in neutralTitles {
        let node = GraphNode(id: UUID(), title: title, tagColor: nil, type: .fleeting, layer: .user, weight: Int.random(in: 0...4))
        nodes.append(node)
        neutralIDs.append(node.id)
    }

    var edges: [GraphEdge] = []
    for clusterIDs in idsByCluster {
        for (i, source) in clusterIDs.enumerated() {
            let connectionCount = Int.random(in: 2...4)
            for _ in 0..<connectionCount {
                var targetIndex = Int.random(in: 0..<clusterIDs.count)
                if targetIndex == i {
                    targetIndex = (targetIndex + 1) % clusterIDs.count
                }
                let target = clusterIDs[targetIndex]
                edges.append(GraphEdge(id: UUID(), sourceId: source, targetId: target, targetTitle: ""))
            }
        }
    }

    for i in 0..<idsByCluster.count {
        let nextIndex = (i + 1) % idsByCluster.count
        let bridges = Int.random(in: 1...2)
        for _ in 0..<bridges {
            guard let source = idsByCluster[i].randomElement(),
                  let target = idsByCluster[nextIndex].randomElement() else { continue }
            edges.append(GraphEdge(id: UUID(), sourceId: source, targetId: target, targetTitle: ""))
        }
    }

    for neutralID in neutralIDs {
        for _ in 0..<Int.random(in: 1...2) {
            guard let target = nodes.randomElement() else { continue }
            edges.append(GraphEdge(id: UUID(), sourceId: neutralID, targetId: target.id, targetTitle: ""))
        }
    }

    let unresolvedTargets = ["Idea Sketch", "Open Question", "TBD: Latency Budget", "Reference Lost", "Future Self"]
    for title in unresolvedTargets {
        guard let source = nodes.randomElement() else { continue }
        edges.append(GraphEdge(id: UUID(), sourceId: source.id, targetId: nil, targetTitle: title))
    }

    let graph = BlockGraph(nodes: nodes, edges: edges)

    return GraphView(graph: graph) { id in
        print("tapped node:", id)
    }
    .frame(width: 980, height: 720)
    .preferredColorScheme(.dark)
}
