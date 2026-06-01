import SwiftUI

struct DockTopBar: View {
    @ObservedObject var stateStore: NotchStateStore
    @Binding var searchText: String
    let count: Int
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 280, alignment: .leading)
            .background(Capsule().fill(.white.opacity(0.08)))
            .onChange(of: searchFocused) { stateStore.searchActive = searchFocused }

            Spacer()

            iconButton("star.fill")
            countBadge
            iconButton("rectangle.on.rectangle")
        }
    }

    private func iconButton(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 30, height: 30)
            .background(Circle().fill(.white.opacity(0.08)))
    }

    private var countBadge: some View {
        Text("\(min(count, 99))")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 30, height: 30)
            .background(Circle().fill(.white.opacity(0.08)))
    }
}
