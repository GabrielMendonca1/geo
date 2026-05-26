import SwiftUI

struct HomeTabView: View {

    var body: some View {
        GeometryReader { geo in
            let dividerWidth: CGFloat = 1
            let upNextWidth = (geo.size.width - dividerWidth) * 0.6
            let shelfWidth = (geo.size.width - dividerWidth) * 0.4

            HStack(spacing: 0) {
                UpNextColumnView()
                    .frame(width: upNextWidth)

                Rectangle()
                    .fill(Palette.border.opacity(0.15))
                    .frame(width: dividerWidth)
                    .padding(.vertical, 12)

                ShelfColumnView()
                    .frame(width: shelfWidth)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }
}
