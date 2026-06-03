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
                    let key = TagStore.canonicalName(tag.name)
                    NotchTagChip(tag: tag, isActive: filter == .tag(key)) {
                        filter = (filter == .tag(key)) ? .all : .tag(key)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }
}
