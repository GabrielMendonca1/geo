import SwiftUI

struct MonthCalendarView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Binding var currentMonth: Date
    let onEventTap: (CalendarEvent) -> Void
    var filter: CalendarFilter
    @Binding var isSidebarOpen: Bool

    let containerSize: CGSize
    private let holidayService: any HolidayServiceProviding

    @StateObject private var viewModel: CalendarViewModel

    init(
        currentMonth: Binding<Date>,
        onEventTap: @escaping (CalendarEvent) -> Void,
        containerSize: CGSize,
        holidayService: any HolidayServiceProviding,
        filter: CalendarFilter = CalendarFilter(),
        isSidebarOpen: Binding<Bool> = .constant(false)
    ) {
        _currentMonth = currentMonth
        self.onEventTap = onEventTap
        self.containerSize = containerSize
        self.filter = filter
        self.holidayService = holidayService
        _isSidebarOpen = isSidebarOpen
        _viewModel = StateObject(
            wrappedValue: CalendarViewModel(holidayService: holidayService)
        )
    }

    private var scale: CGFloat {
        let baseWidth: CGFloat = 900
        let baseHeight: CGFloat = 600
        let widthScale = containerSize.width / baseWidth
        let heightScale = containerSize.height / baseHeight
        let raw = min(max(min(widthScale, heightScale), 0.7), 1.3)
        return (raw * 20).rounded() / 20
    }

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeader(
                currentMonth: $currentMonth,
                isSidebarOpen: $isSidebarOpen,
                scale: scale,
                onTodayTap: scrollToToday
            )

            CalendarWeekdayHeader(scale: scale)
                .padding(.horizontal, 12 * scale)

            Divider()
                .background(Palette.border.opacity(0.10))

            GeometryReader { proxy in
                EquatableView(content: CalendarGrid(
                    currentMonth: $currentMonth,
                    events: viewModel.singleDayEvents,
                    spanningEvents: viewModel.spanningEvents,
                    scale: scale,
                    containerWidth: proxy.size.width,
                    containerHeight: proxy.size.height,
                    onEventTap: handleEventTap
                ))
            }
        }
        .task {
            viewModel.filter = filter
            viewModel.bindIfNeeded(
                tasksRepository: appEnvironment.tasksRepository,
                blocksRepository: appEnvironment.blocksRepository,
                tagsRepository: appEnvironment.tagsRepository
            )
            viewModel.refresh(for: currentMonth)
        }
        .onChange(of: currentMonth) { _, newMonth in
            viewModel.refresh(for: newMonth)
        }
        .onChange(of: filter) { _, newFilter in
            Task { @MainActor in viewModel.filter = newFilter }
        }
    }

    private func scrollToToday() {
        withAnimation(.easeInOut(duration: 0.3)) {
            currentMonth = Date()
        }
    }

    private func handleEventTap(_ event: CalendarEvent) {
        onEventTap(event)
    }
}

extension Date: @retroactive Identifiable {
    public var id: TimeInterval { timeIntervalSince1970 }
}
