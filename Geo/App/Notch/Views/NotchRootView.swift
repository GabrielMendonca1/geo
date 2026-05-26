import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var stateStore: NotchStateStore
    let hasNotch: Bool
    let notchSize: CGSize
    let menubarHeight: CGFloat

    private var isExpanded: Bool {
        stateStore.state == .expanded
    }

    private var topInset: CGFloat {
        hasNotch ? notchSize.height : menubarHeight
    }

    private var dockContentHeight: CGFloat { 260 }
    private var dockWidth: CGFloat { 520 }
    private var dockCornerRadius: CGFloat { 28 }
    private var dockTotalHeight: CGFloat { dockContentHeight + topInset }

    var body: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                expandedDock
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.96, anchor: .top).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var expandedDock: some View {
        DockView(
            stateStore: stateStore,
            notchSize: notchSize,
            hasNotch: hasNotch,
            topInset: topInset
        )
        .frame(width: dockWidth, height: dockTotalHeight)
        .background(
            DynamicIslandShape(cornerRadius: dockCornerRadius)
                .fill(Color.black)
        )
        .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 12)
        .contentShape(DynamicIslandShape(cornerRadius: dockCornerRadius))
    }
}
