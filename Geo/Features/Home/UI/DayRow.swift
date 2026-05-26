import SwiftUI

struct DayRow: View {
    let day: Day
    let blocks: [BlockEntity]
    let captures: [CaptureItem]
    let tasks: [TaskItem]
    let scale: CGFloat

    @State private var isExpanded = false
    @State private var isPopoverPresented = false

    private var dayBlocks: [BlockEntity] {
        let idSet = Set(day.blockIds)
        return blocks.filter { idSet.contains($0.id) }
    }

    private var dayCaptures: [CaptureItem] {
        let idSet = Set(day.captureIds)
        return captures.filter { idSet.contains($0.id) }
    }

    private var dayTasks: [TaskItem] {
        tasks.filter { Calendar.current.isDate($0.startTime, inSameDayAs: day.date) }
    }

    private var hasExpandableArtifacts: Bool {
        !dayBlocks.isEmpty || !dayCaptures.isEmpty
    }

    private var hasPopoverItems: Bool {
        hasExpandableArtifacts || !dayTasks.isEmpty
    }

    private var titleFontSize: CGFloat {
        18 * scale
    }

    private var chevronFontSize: CGFloat {
        12 * scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if hasExpandableArtifacts {
                        isExpanded.toggle()
                    }
                }
                isPopoverPresented = true
            } label: {
                HStack {
                    Text(day.date.formatted(date: .long, time: .omitted))
                        .font(GeoStyle.Typography.titleFont(size: titleFontSize))

                    Spacer()

                    HStack(spacing: 12) {
                        if !dayBlocks.isEmpty {
                            ArtifactBadge(icon: "doc.text", count: dayBlocks.count, scale: scale)
                        }
                        if !dayCaptures.isEmpty {
                            ArtifactBadge(icon: "photo", count: dayCaptures.count, scale: scale)
                        }
                        if !dayTasks.isEmpty {
                            ArtifactBadge(icon: "checkmark.circle", count: dayTasks.count, scale: scale)
                        }
                    }

                    if hasExpandableArtifacts {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: chevronFontSize, weight: .medium))
                            .foregroundStyle(Palette.tertiaryForeground)
                    }
                }
                .padding()
                .contentShape(Rectangle())
            }
            .plainNoFocusButton()
            .disabled(!hasPopoverItems)
            .popover(isPresented: $isPopoverPresented) {
                TimelinePopoverView(
                    date: day.date,
                    tasks: dayTasks,
                    blocks: dayBlocks,
                    captures: dayCaptures
                )
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                        .padding(.horizontal)

                    if !dayBlocks.isEmpty {
                        ArtifactSection(title: "Blocks", icon: "doc.text") {
                            ForEach(dayBlocks) { block in
                                BlockArtifactRow(block: block)
                            }
                        }
                    }

                    if !dayCaptures.isEmpty {
                        ArtifactSection(title: "Captures", icon: "photo") {
                            ForEach(dayCaptures) { capture in
                                CaptureArtifactRow(capture: capture)
                            }
                        }
                    }
                }
                .padding(.bottom)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Palette.secondaryBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.border.opacity(0.2), lineWidth: GeoStyle.Border.width)
        )
    }
}
