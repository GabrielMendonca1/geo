import SwiftUI
import Combine

struct NavigationSegmentedControl: View {
    @Binding var selection: AppTab
    @State private var animationTriggers: [AppTab: Int] = [:]
    private let tabOrder = AppTab.defaultNavigationOrder
    @Namespace private var glassNamespace

    var body: some View {
        tabsContent
    }

    private var tabsContent: some View {
        ZStack {
            HStack(spacing: 2) {
                ForEach(tabOrder) { tab in
                    if selection == tab {
                        RoundedRectangle(cornerRadius: TitleBarMetrics.NavIcon.pillCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .frame(
                                width: TitleBarMetrics.NavIcon.pillSize,
                                height: TitleBarMetrics.NavIcon.pillSize
                            )
                            .frame(
                                width: TitleBarMetrics.NavIcon.hitWidth,
                                height: TitleBarMetrics.stripHeight
                            )
                    } else {
                        Color.clear
                            .frame(
                                width: TitleBarMetrics.NavIcon.hitWidth,
                                height: TitleBarMetrics.stripHeight
                            )
                    }
                }
            }
            buttonsRow
        }
    }

    private var buttonsRow: some View {
        HStack(spacing: 2) {
            ForEach(tabOrder) { tab in
                Button {
                    animationTriggers[tab, default: 0] += 1
                    withAnimation(.bouncy) { selection = tab }
                } label: {
                    TabIconView(
                        tab: tab,
                        isSelected: selection == tab,
                        animationTrigger: animationTriggers[tab, default: 0]
                    )
                    .frame(
                        width: TitleBarMetrics.NavIcon.hitWidth,
                        height: TitleBarMetrics.stripHeight
                    )
                    .contentShape(Rectangle())
                }
                .plainNoFocusButton()
                .accessibilityLabel(tab.displayTitle)
                .accessibilityHint("Switch to \(tab.displayTitle) tab")
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                .hoverTooltip(title: tab.displayTitle, shortcut: tab.shortcutHint)
            }
        }
    }
}

struct TabIconView: View {
    let tab: AppTab
    let isSelected: Bool
    let animationTrigger: Int

    var body: some View {
        Group {
            switch tab {
            case .home:
                Image(systemName: tab.icon)
                    .symbolEffect(.bounce.down.byLayer, value: animationTrigger)
            case .tasks:
                Image(systemName: tab.icon)
                    .symbolEffect(.wiggle.backward.byLayer, value: animationTrigger)
            case .nodes:
                Image(systemName: tab.icon)
                    .symbolEffect(.bounce, value: animationTrigger)
            case .ai:
                Image(systemName: tab.icon)
                    .symbolEffect(.breathe, value: animationTrigger)
            case .nano:
                Image(systemName: tab.icon)
                    .symbolEffect(.pulse, value: animationTrigger)
            case .settings:
                Image(systemName: tab.icon)
            }
        }
        .font(.system(size: TitleBarMetrics.NavIcon.symbolSize, weight: .semibold))
        .foregroundColor(isSelected ? Palette.foreground : Palette.foreground.opacity(0.6))
    }
}

#Preview {
    NavigationSegmentedControl(selection: .constant(.home))
        .padding()
}
