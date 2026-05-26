import SwiftUI

struct ColumnSectionHeader<Trailing: View>: View {
    let title: String
    let icon: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        _ title: String,
        icon: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Palette.agentAccent))
            }

            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Palette.tertiaryForeground)

            Spacer(minLength: 0)

            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

struct ColumnPlusButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.tertiaryForeground)
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(Palette.tertiaryForeground.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}
