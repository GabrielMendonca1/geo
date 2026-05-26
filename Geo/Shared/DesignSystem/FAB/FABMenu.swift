import SwiftUI

struct FABMenu: View {
    let configuration: FABConfiguration
    @Binding var isExpanded: Bool
    var paneIdentifier: String = "default"
    var enableUsageTracking: Bool = true

    @Environment(\.appEnvironment) private var appEnvironment
    @FocusState private var isFABFocused: Bool
    @State private var focusedActionIndex: Int?
    @State private var showShortcutHint: Bool = true

    private let primarySize: CGFloat = 64

    init(
        configuration: FABConfiguration,
        isExpanded: Binding<Bool>,
        paneIdentifier: String = "default",
        enableUsageTracking: Bool = true
    ) {
        self.configuration = configuration
        _isExpanded = isExpanded
        self.paneIdentifier = paneIdentifier
        self.enableUsageTracking = enableUsageTracking
    }

    private var sortedActions: [FABActionItem] {
        guard enableUsageTracking else {
            return configuration.secondaryActions
        }

        let labels = configuration.secondaryActions.map(\.label)
        let orderedLabels = appEnvironment.usageTracker.sortedActionLabels(labels, in: paneIdentifier)
        var labelOrder: [String: Int] = [:]
        for (index, label) in orderedLabels.enumerated() where labelOrder[label] == nil {
            labelOrder[label] = index
        }
        let actions = configuration.secondaryActions.sorted { lhs, rhs in
            let lhsOrder = labelOrder[lhs.label] ?? Int.max
            let rhsOrder = labelOrder[rhs.label] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        return actions
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isExpanded {
                Color.black.opacity(0.28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            isExpanded = false
                        }
                        focusedActionIndex = nil
                    }
            }

            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(sortedActions.enumerated()), id: \.element.id) { index, action in
                    FABAction(
                        item: action,
                        index: index + 1,
                        isExpanded: isExpanded,
                        isFocused: focusedActionIndex == index,
                        onExecute: {
                            if enableUsageTracking {
                                appEnvironment.usageTracker.track(action.label, in: paneIdentifier)
                            }
                            action.action()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                isExpanded = false
                            }
                            focusedActionIndex = nil
                        }
                    )
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.3, anchor: .trailing)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75)
                        .delay(Double(index) * 0.05), value: isExpanded)
                }

                primaryButton
                    .focusEffectDisabled()
            }
        }
        .focusable(isExpanded)
        .focused($isFABFocused)
        .onKeyPress(.upArrow) {
            handleArrowKey(direction: .up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            handleArrowKey(direction: .down)
            return .handled
        }
        .onKeyPress(.return) {
            executeFocusedAction()
            return .handled
        }
        .onKeyPress(.space) {
            executeFocusedAction()
            return .handled
        }
        .onKeyPress(.escape) {
            if isExpanded {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    isExpanded = false
                }
                focusedActionIndex = nil
                return .handled
            }
            return .ignored
        }
        .onKeyPress(keys: ["1", "2", "3", "4", "5"]) { keyPress in
            executeActionByNumber(keyPress.characters)
            return .handled
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded {
                isFABFocused = true
                focusedActionIndex = 0
                if showShortcutHint {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showShortcutHint = false
                    }
                }
            } else {
                focusedActionIndex = nil
            }
        }
    }

    private var primaryButton: some View {
        HStack(spacing: 8) {
            if showShortcutHint && !isExpanded {
                Text("⌘K")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.clear)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                    )
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            Button(action: {
                performHaptic(.levelChange)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                    isExpanded.toggle()
                }
                if showShortcutHint {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showShortcutHint = false
                    }
                }
            }) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: primarySize, height: primarySize)

                    Image(systemName: configuration.primaryIcon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(isExpanded ? 45 : 0))

                    if let badge = configuration.primaryBadge {
                        badgeView(text: badge)
                    }
                }
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(configuration.primaryLabel)
            .accessibilityLabel(configuration.primaryLabel)
            .accessibilityHint("Double-tap to expand menu with \(configuration.secondaryActions.count) options. Press Command-K to toggle.")
            .accessibilityValue(configuration.primaryBadge ?? "")
            .accessibilityAddTraits(.isButton)
        }
    }

    private func badgeView(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.red)
            )
            .offset(x: 20, y: -20)
    }

    private enum ArrowDirection {
        case up, down
    }

    private func handleArrowKey(direction: ArrowDirection) {
        guard isExpanded else { return }

        let actionCount = sortedActions.count
        guard actionCount > 0 else { return }

        performHaptic(.alignment)

        if let current = focusedActionIndex {
            switch direction {
            case .up:
                focusedActionIndex = current > 0 ? current - 1 : actionCount - 1
            case .down:
                focusedActionIndex = current < actionCount - 1 ? current + 1 : 0
            }
        } else {
            focusedActionIndex = 0
        }
    }

    private func executeFocusedAction() {
        guard isExpanded,
              let focusedIndex = focusedActionIndex,
              focusedIndex < sortedActions.count else {
            return
        }

        performHaptic(.generic)

        let action = sortedActions[focusedIndex]
        if enableUsageTracking {
            appEnvironment.usageTracker.track(action.label, in: paneIdentifier)
        }
        action.action()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            isExpanded = false
        }
        focusedActionIndex = nil
    }

    private func executeActionByNumber(_ number: String) {
        guard isExpanded,
              let num = Int(number),
              num > 0,
              num <= sortedActions.count else {
            return
        }

        performHaptic(.generic)

        let action = sortedActions[num - 1]
        if enableUsageTracking {
            appEnvironment.usageTracker.track(action.label, in: paneIdentifier)
        }
        action.action()

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            isExpanded = false
        }
        focusedActionIndex = nil
    }

    private func performHaptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

}
