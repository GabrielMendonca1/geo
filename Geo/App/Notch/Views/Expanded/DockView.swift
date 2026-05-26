import SwiftUI

struct DockView: View {
    @ObservedObject var stateStore: NotchStateStore
    let notchSize: CGSize
    let hasNotch: Bool
    let topInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: topInset)
                .allowsHitTesting(false)

            DockTopBar(stateStore: stateStore)
                .frame(height: 34)

            Divider()
                .background(Palette.border.opacity(0.15))

            HomeTabView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
