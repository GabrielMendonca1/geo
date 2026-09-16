import SwiftUI

struct CalendarView: View {
    @StateObject private var viewModel = CalendarViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    calendarCard
                        .padding(.top, 8)
                    agendaSection
                    trainingSection
                    moneySection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .dockScrollTracking()
            .background(Color.paperCanvas)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .navigationBarHidden(true)
            .refreshable { await viewModel.load() }
        }
        .task { await viewModel.load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Calendário")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(Color.paperCard, in: Capsule())

            Spacer()

            HStack(spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        viewModel.goToToday()
                    }
                } label: {
                    Text("Hoje")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                }
                .accessibilityIdentifier("calendar-today")

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                        viewModel.mode = viewModel.mode == .month ? .week : .month
                    }
                } label: {
                    Image(systemName: viewModel.mode == .month ? "rectangle.grid.1x2" : "square.grid.3x3")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(viewModel.mode == .month ? "Ver semana" : "Ver mês")
                .accessibilityIdentifier("calendar-mode")
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 4)
            .background(Color.paperCard, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Color.paperCanvas)
    }

    // MARK: - Grade

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var calendarCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text(viewModel.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Spacer()
                arrow("chevron.left", step: -1)
                arrow("chevron.right", step: 1)
            }

            HStack(spacing: 4) {
                ForEach(CalGrid.weekdayLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(viewModel.visibleDays, id: \.self) { date in
                    dayCell(date)
                }
            }
            .id(viewModel.visibleDays.first)
            .transition(.opacity)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < -40 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { viewModel.shiftPeriod(by: 1) }
                    } else if value.translation.width > 40 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { viewModel.shiftPeriod(by: -1) }
                    }
                }
        )
    }

    private func arrow(_ symbol: String, step: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { viewModel.shiftPeriod(by: step) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step > 0 ? "Próximo" : "Anterior")
    }

    private func dayCell(_ date: Date) -> some View {
        let cal = CalGrid.calendar
        let isSelected = cal.isDate(viewModel.selectedDate, inSameDayAs: date)
        let isToday = cal.isDateInToday(date)
        let inMonth = viewModel.mode == .week
            || cal.isDate(date, equalTo: viewModel.displayedMonth, toGranularity: .month)
        let markers = viewModel.markers(for: date)

        return VStack(spacing: 3) {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 34, height: 34)
                }
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(color(selected: isSelected, inMonth: inMonth))
            }
            .frame(height: 34)

            HStack(spacing: 3) {
                ForEach(markers.prefix(3)) { marker in
                    Circle()
                        .fill(isSelected ? Color.paperInk.opacity(0.9) : Color.primary.opacity(0.55))
                        .frame(width: 4, height: 4)
                        .opacity(inMonth ? 1 : 0.35)
                        .accessibilityHidden(true)
                        .id(marker.id)
                }
            }
            .frame(height: 4)

            Rectangle()
                .fill(isToday && !isSelected ? Color.primary : .clear)
                .frame(width: 14, height: 1.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { viewModel.select(date) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CalGrid.dayTitle(for: date))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func color(selected: Bool, inMonth: Bool) -> Color {
        if selected { return Color.paperInk }
        return inMonth ? Color.primary : Color.primary.opacity(0.3)
    }

    // MARK: - Agenda

    private var agendaSection: some View {
        section(title: "Tarefas e eventos", subtitle: viewModel.dayTitle) {
            let items = viewModel.agenda(for: viewModel.selectedDate)
            if items.isEmpty {
                emptyRow
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rowDivider }
                    agendaRow(item)
                }
            }
        }
    }

    private func agendaRow(_ item: CalendarAgendaItem) -> some View {
        HStack(spacing: 14) {
            Group {
                switch item {
                case .task(let task):
                    Button {
                        viewModel.toggle(task)
                    } label: {
                        Image(systemName: task.status == .completed ? "circle.inset.filled" : "circle")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(task.status == .completed ? Color.primary : Color.primary.opacity(0.3))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(task.status == .completed ? "Reabrir" : "Concluir")
                case .event:
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.primary.opacity(0.35))
                        .frame(width: 32, height: 32)
                }
            }

            Text(item.title)
                .font(.system(size: 17))
                .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                .strikethrough(item.isDone, color: .secondary)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let time = item.timeLabel {
                Text(time)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Treino

    private var trainingSection: some View {
        section(title: "Treino", subtitle: nil) {
            if let entry = viewModel.training(for: viewModel.selectedDate) {
                trainingRow(
                    muscles: entry.muscles,
                    title: entry.rest ? "Descanso" : entry.label,
                    detail: entry.rest ? "Dia sem treino" : MuscleNames.line(entry.muscles),
                    rest: entry.rest
                )
            } else if let session = viewModel.legacySession(for: viewModel.selectedDate) {
                trainingRow(
                    muscles: session.muscles,
                    title: session.rest ? "Descanso" : session.name,
                    detail: session.rest ? "Dia sem treino" : MuscleNames.line(session.muscles),
                    rest: session.rest
                )
            } else {
                emptyRow
            }
        }
    }

    private func trainingRow(muscles: [String], title: String, detail: String, rest: Bool) -> some View {
        HStack(spacing: 14) {
            if rest || muscles.isEmpty {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.paperTile, in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))
            } else {
                MuscleTile(muscles: muscles)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Financeiro

    private var moneySection: some View {
        section(title: "Financeiro", subtitle: nil) {
            let items = viewModel.moneyItems(for: viewModel.selectedDate)
            if items.isEmpty {
                emptyRow
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { rowDivider }
                    moneyRow(item)
                }
            }
        }
    }

    private func moneyRow(_ item: CalendarMoneyItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.projected ? "arrow.triangle.2.circlepath" : (item.kind == .income ? "arrow.down.left" : "arrow.up.right"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background(Color.paperTile, in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.category)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                if item.projected {
                    Text("Recorrente")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(item.amountText)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(item.projected ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Peças

    private func section<Content: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                }
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity)
            .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
        }
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, 74)
            .padding(.trailing, 20)
    }

    private var emptyRow: some View {
        Text("Nada agendado")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }
}

#Preview {
    CalendarView()
}
