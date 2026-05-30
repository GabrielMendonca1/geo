import SwiftUI

struct NotchTagBar: View {
    let tags: [Tag]
    @Binding var selectedTagId: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                NotchChip(title: "All", isActive: selectedTagId == nil) {
                    selectedTagId = nil
                }
                ForEach(tags) { tag in
                    NotchTagChip(tag: tag, isActive: selectedTagId == tag.id) {
                        selectedTagId = (selectedTagId == tag.id) ? nil : tag.id
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }
}
