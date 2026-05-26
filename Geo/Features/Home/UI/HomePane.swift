import SwiftUI

struct HomePane: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.openWindow) private var openWindow

    @State private var currentMonth: Date = Date()
    @StateObject private var sidebarVM = CalendarSidebarViewModel()
    @State private var editingTask: TaskItem?
    @State private var showTaskForm = false
    @State private var blockOptions: [TaskBlockOption] = []

    var body: some View {
        let _ = PerformanceTracker.shared.recordRender("HomePane")
        Pane {
            HStack(spacing: 0) {
                GeometryReader { proxy in
                    MonthCalendarView(
                        currentMonth: $currentMonth,
                        onEventTap: handleEventTap,
                        containerSize: proxy.size,
                        holidayService: appEnvironment.holidayService,
                        filter: sidebarVM.filter,
                        isSidebarOpen: $sidebarVM.isOpen
                    )
                    .frame(minWidth: 400)
                }

                if sidebarVM.isOpen {
                    Divider()

                    CalendarSidebarView(
                        currentMonth: $currentMonth,
                        viewModel: sidebarVM,
                        onEditTask: { task in
                            editingTask = task
                            showTaskForm = true
                        }
                    )
                    .frame(width: 300)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 600)
        .animation(.easeInOut(duration: 0.2), value: sidebarVM.isOpen)
        .sheet(isPresented: $showTaskForm, onDismiss: { editingTask = nil }) {
            TaskFormView(
                editingTask: editingTask,
                availableBlocks: blockOptions
            )
        }
        .task {
            for await blocks in appEnvironment.blocksRepository.observe() {
                blockOptions = blocks.map { TaskBlockOption(block: $0) }
            }
        }
    }

    private func handleEventTap(_ event: CalendarEvent) {
        switch event.type {
        case .task:
            sidebarVM.selectedEvent = event
            sidebarVM.isOpen = true
        case let .block(block):
            openWindow(id: "editor", value: block.id)
        case .holiday:
            sidebarVM.selectedEvent = event
            sidebarVM.isOpen = true
        }
    }
}
