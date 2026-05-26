import SwiftUI

struct CalendarSidebarView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    @Binding var currentMonth: Date
    @ObservedObject var viewModel: CalendarSidebarViewModel
    let onEditTask: (TaskItem) -> Void

    @State private var tags: [Tag] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sidebarSection(title: "Navigate", icon: "calendar") {
                    CalendarMiniMonthView(currentMonth: $currentMonth)
                }

                sidebarSection(title: "Filters", icon: "line.3.horizontal.decrease") {
                    CalendarFilterView(viewModel: viewModel, tags: tags)
                }

                if let event = viewModel.selectedEvent {
                    sidebarSection(title: nil, icon: nil) {
                        CalendarEventDetailView(
                            event: event,
                            onDismiss: { viewModel.clearSelection() },
                            onEdit: onEditTask,
                            onStatusToggled: { viewModel.selectedEvent = $0 }
                        )
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.selectedEvent != nil)
        }
        .frame(minWidth: 300)
        .background(Palette.secondaryBackground.opacity(0.3))
        .task {
            for await observed in appEnvironment.tagsRepository.observe() {
                tags = observed
            }
        }
    }

    @ViewBuilder
    private func sidebarSection<Content: View>(
        title: String?,
        icon: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, let icon {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.tertiaryForeground)
                        .tracking(0.5)
                        .accessibilityAddTraits(.isHeader)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }

            content()

            Divider()
                .padding(.horizontal, 8)
        }
    }
}
