import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var stateStore: NotchStateStore
    let metrics: NotchMetrics

    private var isExpanded: Bool { stateStore.state == .expanded }

    var body: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                dock
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var dock: some View {
        DockView(stateStore: stateStore, metrics: metrics)
            .frame(width: metrics.dockWidth, height: metrics.dockHeight)
            .background(
                DynamicIslandShape(cornerRadius: NotchMetrics.cornerRadius)
                    .fill(Color.black)
            )
            .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 12)
            .contentShape(DynamicIslandShape(cornerRadius: NotchMetrics.cornerRadius))
    }
}
