import AppKit
import SwiftUI

struct GraphView: View {
    let graph: BlockGraph
    var seedPositions: [UUID: CGPoint]
    var wasSettled: Bool
    var externalChangeSignal: ExternalChangeSignal?
    var onLayoutChange: (([UUID: CGPoint], Bool) -> Void)?
    var isActive: (() -> Bool)?
    var persistsSettings: Bool
    var initialFitScale: CGFloat
    var maxInitialZoom: CGFloat
    var minZoom: CGFloat
    var searchQuery: String
    var onNodeTap: (UUID) -> Void

    init(
        graph: BlockGraph,
        seedPositions: [UUID: CGPoint] = [:],
        wasSettled: Bool = false,
        externalChangeSignal: ExternalChangeSignal? = nil,
        onLayoutChange: (([UUID: CGPoint], Bool) -> Void)? = nil,
        isActive: (() -> Bool)? = nil,
        persistsSettings: Bool = true,
        initialFitScale: CGFloat = 0.85,
        maxInitialZoom: CGFloat = 2.4,
        minZoom: CGFloat = 0.15,
        searchQuery: String = "",
        onNodeTap: @escaping (UUID) -> Void
    ) {
        self.graph = graph
        self.seedPositions = seedPositions
        self.wasSettled = wasSettled
        self.externalChangeSignal = externalChangeSignal
        self.onLayoutChange = onLayoutChange
        self.isActive = isActive
        self.persistsSettings = persistsSettings
        self.initialFitScale = initialFitScale
        self.maxInitialZoom = maxInitialZoom
        self.minZoom = minZoom
        self.searchQuery = searchQuery
        self.onNodeTap = onNodeTap
        let viewport = Self.bootstrappedViewport()
        _zoom = State(initialValue: CGFloat(viewport.zoom))
        _pendingZoom = State(initialValue: CGFloat(viewport.zoom))
        _pan = State(initialValue: CGSize(width: viewport.panX, height: viewport.panY))
    }

    private static let nodeSizeScale: CGFloat = 1.3
    private static let lineThickness: CGFloat = 1.0
    private static let textFadeThreshold: CGFloat = 0.6
    private static let labelHideZoom: CGFloat = 0.35
    private static let maxZoom: CGFloat = 2.4
    // Above this many highlighted matches, stop forcing always-on labels — a broad
    // query (e.g. one letter) would otherwise stack hundreds of overlapping labels.
    private static let searchLabelForceCap = 40

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.tabRouter) private var tabRouter
    @StateObject private var simulation = GraphSimulation()
    @State private var externalPulses: [UUID: Date] = [:]
    @State private var removalPulses: [UUID: (position: CGPoint, radius: CGFloat, start: Date)] = [:]
    private static let pulseDuration: TimeInterval = 1.2
    private static let removalDuration: TimeInterval = 0.9

    @State private var zoom: CGFloat
    @State private var pendingZoom: CGFloat
    @State private var pan: CGSize
    @State private var pendingPan: CGSize = .zero
    @State private var hoverNodeID: UUID?
    @State private var draggingNodeID: UUID?
    @State private var selectedNodeID: UUID?
    @State private var canvasSize: CGSize = .zero
    @State private var hasFramedInitialLayout = false
    @State private var mouseDownPoint: CGPoint?
    @State private var mouseDownNodeID: UUID?

    @State private var zoomPersistTask: Task<Void, Never>?

    @State private var cachedFocusedID: UUID?
    @State private var cachedNeighbors: Set<UUID> = []
    @State private var searchMatchIDs: Set<UUID> = []
    @State private var stubAngles: [UUID: CGFloat] = [:]
    @State private var renderTick: UInt64 = 0

    var body: some View {
        GeometryReader { geo in
            stackedContent
                .onAppear {
                    onAppearActions(size: geo.size)
                }
                .onDisappear {
                    onLayoutChange?(simulation.positionsSnapshot, simulation.isSettled)
                }
                .onChange(of: geo.size) { _, newSize in canvasSize = newSize }
                .onChange(of: graph) { oldGraph, newGraph in handleGraphChange(from: oldGraph, to: newGraph) }
                .onChange(of: externalChangeSignal) { _, signal in handleExternalSignal(signal) }
                .onChange(of: simulation.isSettled) { _, settled in handleSettledChange(settled) }
                .onChange(of: hoverNodeID) { _, _ in recomputeFocusCache() }
                .onChange(of: selectedNodeID) { _, _ in recomputeFocusCache() }
                .onChange(of: searchQuery) { _, q in recomputeSearchMatches(q) }
        }
    }

    private static func stubAngles(for graph: BlockGraph) -> [UUID: CGFloat] {
        var angles: [UUID: CGFloat] = [:]
        for edge in graph.edges where edge.targetId == nil {
            var hash: UInt32 = 2166136261
            for byte in edge.targetTitle.utf8 {
                hash = (hash ^ UInt32(byte)) &* 16777619
            }
            for byte in edge.sourceId.uuidString.utf8 {
                hash = (hash ^ UInt32(byte)) &* 16777619
            }
            angles[edge.id] = CGFloat(hash % 360) * .pi / 180
        }
        return angles
    }

    private func handleGraphChange(from oldGraph: BlockGraph, to newGraph: BlockGraph) {
        detectCRUDPulses(from: oldGraph, to: newGraph)
        simulation.ingest(graph: newGraph)
        stubAngles = Self.stubAngles(for: newGraph)
        let valid = Set(newGraph.nodes.map(\.id))
        if let sel = selectedNodeID, !valid.contains(sel) { selectedNodeID = nil }
        if let hov = hoverNodeID, !valid.contains(hov) { hoverNodeID = nil }
        if let drag = draggingNodeID, !valid.contains(drag) { draggingNodeID = nil }
        if !externalPulses.isEmpty {
            externalPulses = externalPulses.filter { valid.contains($0.key) }
        }
        recomputeFocusCache()
        recomputeSearchMatches(searchQuery)
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

    private enum IncidentEdge: Hashable {
        case outgoing(UUID)
        case incoming(UUID)
        case unresolved(String)
    }

    private func incidentSignatures(_ graph: BlockGraph) -> [UUID: Set<IncidentEdge>] {
        var sig: [UUID: Set<IncidentEdge>] = [:]
        for edge in graph.edges {
            if let target = edge.targetId {
                sig[edge.sourceId, default: []].insert(.outgoing(target))
                sig[target, default: []].insert(.incoming(edge.sourceId))
            } else {
                sig[edge.sourceId, default: []].insert(.unresolved(edge.targetTitle))
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

    private var simulationActive: Bool { !simulation.isSettled || draggingNodeID != nil || hasActiveEffects }

    private func recomputeFocusCache() {
        let focused = hoverNodeID ?? selectedNodeID
        cachedFocusedID = focused
        cachedNeighbors = focused.map(neighborSet) ?? []
    }

    private static func searchKey(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private func recomputeSearchMatches(_ query: String) {
        let needle = Self.searchKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else {
            if !searchMatchIDs.isEmpty { searchMatchIDs = [] }
            return
        }
        var matches = Set<UUID>()
        for node in graph.nodes where Self.searchKey(node.title).contains(needle) {
            matches.insert(node.id)
        }
        searchMatchIDs = matches
    }

    private var searchActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // The set of nodes drawn at full opacity. Hover/selection wins over search so
    // poking the graph mid-query still focuses the node under the cursor.
    private var highlightContext: (highlighted: Set<UUID>, ringed: Set<UUID>, dimOthers: Bool) {
        if cachedFocusedID != nil {
            return (cachedNeighbors, cachedFocusedID.map { [$0] } ?? [], true)
        }
        if searchActive {
            return (searchMatchIDs, searchMatchIDs, true)
        }
        return ([], [], false)
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
            onLayoutChange?(simulation.positionsSnapshot, true)
        }
    }

    private var stackedContent: some View {
        ZStack(alignment: .topTrailing) {
            backgroundLayer
            simulationCanvas
            gestureLayer
            scrollWheelLayer
        }
    }

    private var gestureLayer: some View {
        MouseEventMonitor(
            isActiveCheck: { [tabRouter, isActive] in isActive?() ?? (tabRouter.selectedTab == .nodes) },
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
            persistViewport()
        }
    }

    private var simulationCanvas: some View {
        Canvas(rendersAsynchronously: true) { canvasContext, size in
            _ = renderTick
            renderCanvas(canvasContext: canvasContext, size: size)
        }
        .allowsHitTesting(false)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: simulationActive ? 16_666_000 : 150_000_000)
                guard simulationActive else { continue }
                simulation.step()
                pruneEffects(now: Date())
                renderTick &+= 1
            }
        }
    }

    private var scrollWheelLayer: some View {
        ScrollWheelMonitor(isActiveCheck: { [tabRouter, isActive] in isActive?() ?? (tabRouter.selectedTab == .nodes) }) { delta in
            let next = max(minZoom, min(Self.maxZoom, zoom * (1 + delta)))
            zoom = next
            pendingZoom = next
            scheduleZoomPersist()
        }
        .allowsHitTesting(false)
    }

    private func scheduleZoomPersist() {
        zoomPersistTask?.cancel()
        zoomPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            persistViewport()
        }
    }

    private func onAppearActions(size: CGSize) {
        canvasSize = size
        if !seedPositions.isEmpty {
            simulation.seedCachedPositions(seedPositions, settled: wasSettled)
        }
        simulation.ingest(graph: graph)
        stubAngles = Self.stubAngles(for: graph)
        recomputeFocusCache()
        recomputeSearchMatches(searchQuery)
        frameInitialLayoutIfNeeded()
    }

    private func frameInitialLayoutIfNeeded() {
        guard !hasFramedInitialLayout,
              seedPositions.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0,
              !simulation.isEmpty else { return }
        hasFramedInitialLayout = true
        let size = canvasSize
        DispatchQueue.main.async {
            simulation.prewarm(maxSteps: 480)
            fitToView(in: size)
        }
    }

    private func fitToView(in size: CGSize) {
        let items = simulation.fitItems
        guard !items.isEmpty else { return }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for item in items {
            let r = item.radius * Self.nodeSizeScale
            minX = min(minX, item.position.x - r); maxX = max(maxX, item.position.x + r)
            minY = min(minY, item.position.y - r); maxY = max(maxY, item.position.y + r)
        }
        let bboxW = max(maxX - minX, 1), bboxH = max(maxY - minY, 1)
        let fit = min(size.width / bboxW, size.height / bboxH) * initialFitScale
        let newZoom = max(minZoom, min(maxInitialZoom, fit))
        zoom = newZoom
        pendingZoom = newZoom
        pan = CGSize(width: -(minX + maxX) / 2 * newZoom, height: -(minY + maxY) / 2 * newZoom)
        pendingPan = .zero
    }

    static func canvasColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.06) : Color.white
    }

    private var backgroundColor: Color {
        Self.canvasColor(for: colorScheme)
    }

    private var backgroundLayer: some View {
        backgroundColor.ignoresSafeArea()
    }

    private static let viewportKey = "geo.graphViewport.v1"

    private static func bootstrappedViewport() -> GraphViewport {
        let data = UserDefaults.standard.data(forKey: viewportKey)
        var viewport = (data.flatMap { try? JSONDecoder().decode(GraphViewport.self, from: $0) }) ?? GraphViewport()
        viewport.zoom = min(max(viewport.zoom, 0.15), 2.4)
        viewport.panX = min(max(viewport.panX, -5000), 5000)
        viewport.panY = min(max(viewport.panY, -5000), 5000)
        return viewport
    }

    private func persistViewport() {
        guard persistsSettings else { return }
        let viewport = GraphViewport(zoom: Double(zoom), panX: Double(pan.width), panY: Double(pan.height))
        if let data = try? JSONEncoder().encode(viewport) {
            UserDefaults.standard.set(data, forKey: Self.viewportKey)
        }
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

    private func labelOpacity(for node: GraphNode, isHighlighted: Bool, forcesLabel: Bool, dimOthers: Bool) -> Double {
        if forcesLabel { return 1.0 }
        let zoomFactor: Double
        if effectiveZoom >= Self.textFadeThreshold {
            zoomFactor = 1.0
        } else {
            let weightBoost = min(1.0, Double(node.weight) / 12.0)
            let fade = Double((Self.textFadeThreshold - effectiveZoom) / (Self.textFadeThreshold - Self.labelHideZoom))
            zoomFactor = max(0.0, weightBoost - fade)
        }
        if dimOthers {
            return isHighlighted ? min(1.0, 0.85 * zoomFactor) : 0.15 * zoomFactor
        }
        return zoomFactor * 0.85
    }

    private var effectiveZoom: CGFloat { pendingZoom }
    private var effectivePan: CGSize { CGSize(width: pan.width + pendingPan.width, height: pan.height + pendingPan.height) }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pendingZoom = max(minZoom, min(Self.maxZoom, zoom * value))
            }
            .onEnded { value in
                zoom = max(minZoom, min(Self.maxZoom, zoom * value))
                pendingZoom = zoom
                persistViewport()
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
        simulation.nearestNode(to: unprojected(viewPoint), scale: Self.nodeSizeScale, slop: 4)
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
        let ctx = canvasContext
        let snapshot = simulation.renderSnapshot
        let (highlighted, ringed, dimOthers) = highlightContext
        let forceMatchLabels = ringed.count <= Self.searchLabelForceCap

        let edgeBaseColor = Color(white: 0.5)
        let cullMargin: CGFloat = 120
        let minVX = -cullMargin, maxVX = size.width + cullMargin
        let minVY = -cullMargin, maxVY = size.height + cullMargin

        var solidBuckets: [Double: Path] = [:]
        var dashedBuckets: [Double: Path] = [:]

        for edge in graph.edges {
            guard let sourcePos = snapshot.positions[edge.sourceId] else { continue }
            let sourceView = projected(sourcePos)
            let resolved = edge.targetId.flatMap { snapshot.positions[$0] }
            let targetView: CGPoint
            let isResolved: Bool
            if let resolved {
                targetView = projected(resolved)
                isResolved = true
            } else {
                let angle = Double(stubAngles[edge.id] ?? 0)
                let length: CGFloat = 70
                let virtualWorld = CGPoint(x: sourcePos.x + CGFloat(Foundation.cos(angle)) * length, y: sourcePos.y + CGFloat(Foundation.sin(angle)) * length)
                targetView = projected(virtualWorld)
                isResolved = false
            }

            if max(sourceView.x, targetView.x) < minVX || min(sourceView.x, targetView.x) > maxVX
                || max(sourceView.y, targetView.y) < minVY || min(sourceView.y, targetView.y) > maxVY {
                continue
            }

            let edgeHighlighted: Bool = {
                guard dimOthers, highlighted.contains(edge.sourceId) else { return false }
                if let target = edge.targetId { return highlighted.contains(target) }
                return true
            }()

            let baseOpacity: Double = isResolved ? 0.35 : 0.18
            let opacity: Double
            if dimOthers {
                opacity = edgeHighlighted ? (isResolved ? 1.0 : 0.55) : 0.08
            } else {
                opacity = baseOpacity
            }

            if isResolved {
                solidBuckets[opacity, default: Path()].move(to: sourceView)
                solidBuckets[opacity]?.addLine(to: targetView)
            } else {
                dashedBuckets[opacity, default: Path()].move(to: sourceView)
                dashedBuckets[opacity]?.addLine(to: targetView)
            }
        }

        let edgeWidth = 0.5 * Self.lineThickness
        for (opacity, path) in solidBuckets.sorted(by: { $0.key < $1.key }) {
            ctx.stroke(path, with: .color(edgeBaseColor.opacity(opacity)), style: StrokeStyle(lineWidth: edgeWidth, lineCap: .round))
        }
        for (opacity, path) in dashedBuckets.sorted(by: { $0.key < $1.key }) {
            ctx.stroke(path, with: .color(edgeBaseColor.opacity(opacity)), style: StrokeStyle(lineWidth: edgeWidth, lineCap: .round, dash: [2, 3]))
        }

        let renderNow = Date()
        var pendingLabels: [(title: String, point: CGPoint, opacity: Double, isFocused: Bool)] = []
        for node in graph.nodes {
            guard let worldPos = snapshot.positions[node.id], let radius = snapshot.radii[node.id] else { continue }
            let center = projected(worldPos)
            if center.x < minVX || center.x > maxVX || center.y < minVY || center.y > maxVY { continue }
            let scaledRadius = radius * Self.nodeSizeScale * effectiveZoom
            let isRinged = ringed.contains(node.id)
            let isHighlighted = highlighted.contains(node.id)

            let baseColor = node.tagColor ?? Self.defaultColor(for: node.type)

            let alpha: Double = dimOthers ? (isHighlighted ? 1.0 : 0.15) : 1.0

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

            if isRinged {
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

            let textOpacity = labelOpacity(for: node, isHighlighted: isHighlighted, forcesLabel: isRinged && forceMatchLabels, dimOthers: dimOthers)
            if textOpacity > 0.02 {
                let labelPoint = CGPoint(x: center.x, y: center.y + scaledRadius + 4)
                pendingLabels.append((node.title, labelPoint, textOpacity, isRinged))
            }
        }

        for (_, ghost) in removalPulses {
            let elapsed = renderNow.timeIntervalSince(ghost.start)
            guard elapsed >= 0, elapsed < Self.removalDuration else { continue }
            let t = elapsed / Self.removalDuration
            let center = projected(ghost.position)
            let scaled = ghost.radius * Self.nodeSizeScale * effectiveZoom
            let ringRadius = scaled + CGFloat(t) * 16
            let ringAlpha = (1 - t) * 0.5
            let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
            ctx.stroke(Path(ellipseIn: ringRect), with: .color(Color(white: 0.55).opacity(ringAlpha)), lineWidth: 1.2)
        }

        let labelBase = Color(white: colorScheme == .dark ? 0.7 : 0.3)
        for label in pendingLabels {
            let text = Text(label.title)
                .font(.system(size: 11, weight: label.isFocused ? .medium : .regular))
                .foregroundColor(labelBase.opacity(label.opacity))
            ctx.draw(text, at: label.point, anchor: .top)
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
