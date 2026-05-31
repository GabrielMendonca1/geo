import SwiftUI

struct NotchFilterBar: View {
    let tags: [Tag]
    @Binding var filter: NotchFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NotchChip(title: "History", isActive: filter == .all) { filter = .all }
                NotchChip(title: "Images", isActive: filter == .images) { filter = .images }
                NotchChip(title: "Blocks", isActive: filter == .blocks) { filter = .blocks }
                ForEach(tags) { tag in
                    NotchTagChip(tag: tag, isActive: filter == .tag(tag.id)) {
                        filter = (filter == .tag(tag.id)) ? .all : .tag(tag.id)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }
}
