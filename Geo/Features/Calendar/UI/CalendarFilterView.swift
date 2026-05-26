import SwiftUI

struct CalendarFilterView: View {
    @ObservedObject var viewModel: CalendarSidebarViewModel
    let tags: [Tag]

    @State private var tagsExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CalendarFilterType.allCases, id: \.self) { type in
                filterToggle(
                    label: type.label,
                    icon: type.icon,
                    isOn: !viewModel.filter.hiddenTypes.contains(type)
                ) {
                    viewModel.toggleType(type)
                }
            }

            if !tags.isEmpty {
                Divider()
                    .padding(.vertical, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        tagsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tag")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.foreground.opacity(0.7))
                        Text("Tags")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.foreground)
                        Spacer()
                        Image(systemName: tagsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                if tagsExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(tags) { tag in
                            tagToggle(tag: tag)
                        }

                        filterToggle(
                            label: "Untagged",
                            icon: "tag.slash",
                            isOn: viewModel.filter.showUntagged
                        ) {
                            viewModel.toggleUntagged()
                        }
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .padding(10)
    }

    private func filterToggle(label: String, icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Palette.accent : Palette.tertiaryForeground)

                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.foreground.opacity(0.7))

                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func tagToggle(tag: Tag) -> some View {
        let isOn = !viewModel.filter.hiddenTagIds.contains(tag.id)
        return Button {
            viewModel.toggleTag(tag.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? Palette.accent : Palette.tertiaryForeground)

                Circle()
                    .fill(tag.color.swiftUIColor)
                    .frame(width: 9, height: 9)

                Text(tag.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.foreground)
                    .lineLimit(1)

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}
