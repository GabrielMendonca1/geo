import GeoCore
import SwiftUI
import UIKit

/// Aba Tarefas: inbox simples (círculo + título), concluídas no fim,
/// modo de seleção com barra preta e painel de foco.
struct TasksView: View {
    @StateObject private var viewModel = TasksViewModel()
    @StateObject private var focus = FocusSessionModel()
    @State private var composing = false
    @State private var searching = false
    @State private var query = ""
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var showFocusPanel = false
    @State private var runningFocus = false
    @State private var confirmingDelete = false
    @State private var focusTitle = "Foco"
    @State private var rescheduling: RescheduleRequest?
    @AppStorage("tasksShowCompleted") private var showCompleted = false
    @FocusState private var searchFocused: Bool

    /// Tarefas escolhidas para "Mover data" (linha ou seleção múltipla).
    private struct RescheduleRequest: Identifiable {
        let ids: Set<String>
        let anchor: Date
        var id: String { ids.sorted().joined(separator: ",") }
    }

    private var pending: [TaskItem] { filter(viewModel.pending) }
    private var completed: [TaskItem] { showCompleted ? filter(viewModel.completed) : [] }

    private func filter(_ tasks: [TaskItem]) -> [TaskItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return tasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                content
                if !selecting && !showFocusPanel {
                    fab
                }
            }
            .background(Color.paperCanvas)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .overlay(alignment: .bottom) { bottomLayer }
            .navigationBarHidden(true)
        }
        .tint(Color.primary)
        .sheet(isPresented: $composing) {
            NewTaskSheet { draft in
                viewModel.create(draft)
            }
        }
        .sheet(item: $rescheduling) { request in
            RescheduleSheet(count: request.ids.count, initialDate: request.anchor) { date in
                viewModel.reschedule(ids: request.ids, to: date)
                if selecting { endSelection() }
            }
        }
        .fullScreenCover(isPresented: $runningFocus) {
            FocusSessionView(session: focus, title: focusTitle) {
                focus.stop()
                runningFocus = false
            }
        }
        .confirmationDialog(
            "Excluir \(selection.count) tarefa\(selection.count == 1 ? "" : "s")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Excluir", role: .destructive) {
                viewModel.delete(ids: selection)
                endSelection()
            }
        }
        .task {
            await viewModel.reload()
            #if DEBUG
            applyLaunchArguments()
            #endif
        }
    }

    #if DEBUG
    /// Suporte a `-geoNewTask` e `-geoReschedule` para captura de telas.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        if args.contains("-geoNewTask"), rescheduling == nil {
            composing = true
        }
        if args.contains("-geoReschedule"), let first = pending.first {
            composing = false
            rescheduling = request(for: first)
        }
    }
    #endif

    private func request(for task: TaskItem) -> RescheduleRequest {
        RescheduleRequest(ids: [task.id], anchor: TasksDate.scheduled(task) ?? Date())
    }

    private func rescheduleSelection() {
        let ordered = pending + completed
        let anchor = ordered.first { selection.contains($0.id) }.flatMap(TasksDate.scheduled) ?? Date()
        rescheduling = RescheduleRequest(ids: selection, anchor: anchor)
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading, !viewModel.hasLoaded, viewModel.isEmpty {
            ProgressView()
                .tint(.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage, viewModel.isEmpty {
            errorState(error)
        } else if pending.isEmpty && completed.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(pending) { task in
                row(task)
            }
            ForEach(completed) { task in
                row(task)
            }
            Color.clear
                .frame(height: 110)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.paperCanvas)
        .scrollDismissesKeyboard(.immediately)
        .dockScrollTracking()
        .refreshable { await viewModel.reload() }
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: viewModel.pending)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: viewModel.completed)
    }

    private func row(_ task: TaskItem) -> some View {
        let done = task.status == .completed
        let picked = selection.contains(task.id)
        return HStack(spacing: 14) {
            Button {
                if selecting {
                    toggle(task)
                } else {
                    tap(task)
                }
            } label: {
                marker(done: done, picked: picked)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Reabrir" : "Concluir")

            Text(task.title.isEmpty ? "Sem título" : task.title)
                .font(.system(size: 19))
                .foregroundStyle(done ? Color.secondary : Color.primary)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting { toggle(task) }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                viewModel.delete(task)
            } label: {
                Label("Excluir", systemImage: "trash")
            }
            if !done {
                Button {
                    tap(task)
                } label: {
                    Label("Concluir", systemImage: "checkmark")
                }
                .tint(.gray)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                selecting = true
                selection = [task.id]
            } label: {
                Label("Selecionar", systemImage: "checkmark.circle")
            }
            .tint(Color.primary)
            Button {
                rescheduling = request(for: task)
            } label: {
                Label("Mover", systemImage: "calendar")
            }
            .tint(.gray)
        }
        .contextMenu {
            Button {
                rescheduling = request(for: task)
            } label: {
                Label("Mover", systemImage: "calendar")
            }
            Button {
                tap(task)
            } label: {
                Label(done ? "Reabrir" : "Concluir", systemImage: done ? "arrow.uturn.backward" : "checkmark")
            }
            Button(role: .destructive) {
                viewModel.delete(task)
            } label: {
                Label("Excluir", systemImage: "trash")
            }
        } preview: {
            titlePreview(task)
        }
    }

    /// Cartão mostrado ao segurar a linha: título completo sem truncar.
    private func titlePreview(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title.isEmpty ? "Sem título" : task.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let label = TasksDate.label(task) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: UIScreen.main.bounds.width - 48, alignment: .leading)
        .background(Color.paperCard)
    }

    @ViewBuilder
    private func marker(done: Bool, picked: Bool) -> some View {
        ZStack {
            if selecting {
                Circle()
                    .strokeBorder(picked ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    .background(Circle().fill(picked ? Color.primary : Color.clear))
                if picked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.paperInk)
                }
            } else if done {
                Circle().fill(Color.primary)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.paperInk)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
    }

    private func tap(_ task: TaskItem) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            if task.status == .completed {
                viewModel.reopen(task)
            } else {
                viewModel.complete(task)
            }
        }
    }

    private func toggle(_ task: TaskItem) {
        if selection.contains(task.id) {
            selection.remove(task.id)
        } else {
            selection.insert(task.id)
        }
    }

    // MARK: - Estados

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(query.isEmpty ? "Nada por aqui" : "Nada encontrado")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Tentar de novo") {
                Task { await viewModel.reload() }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            if selecting {
                selectionHeader
            } else {
                normalHeader
            }
            if searching, !selecting {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Color.paperCanvas)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searching)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: selecting)
    }

    private var normalHeader: some View {
        HStack {
            Text("Tarefas")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.primary)
            Spacer()
            HStack(spacing: 0) {
                Button {
                    searching.toggle()
                    if searching {
                        searchFocused = true
                    } else {
                        query = ""
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Buscar")
                .accessibilityIdentifier("tasks-search")

                Menu {
                    Button {
                        selecting = true
                        selection = []
                    } label: {
                        Label("Selecionar", systemImage: "checkmark.circle")
                    }
                    Button {
                        startFocusPanel(title: "Foco")
                    } label: {
                        Label("Foco", systemImage: "timer")
                    }
                    Divider()
                    Button {
                        withAnimation { showCompleted.toggle() }
                    } label: {
                        Label(showCompleted ? "Ocultar concluídas" : "Mostrar concluídas",
                              systemImage: showCompleted ? "eye.slash" : "eye")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Mais")
                .accessibilityIdentifier("tasks-menu")
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 4)
            .background(Color.paperCard, in: Capsule())
        }
    }

    private var selectionHeader: some View {
        HStack {
            Button("Cancelar") { endSelection() }
                .font(.system(size: 17))
                .accessibilityIdentifier("tasks-selection-cancel")
            Spacer()
            Button("Selecionar tudo") {
                selection = Set((pending + completed).map(\.id))
            }
            .font(.system(size: 17))
            .accessibilityIdentifier("tasks-selection-all")
        }
        .foregroundStyle(Color.primary)
        .frame(height: 44)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar tarefa", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("tasks-search-field")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Limpar busca")
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.paperCard, in: Capsule())
    }

    // MARK: - Rodapé (seleção + foco)

    @ViewBuilder
    private var bottomLayer: some View {
        if showFocusPanel {
            FocusPanel(
                session: focus,
                subtitle: focusSubtitle,
                onStart: startSession,
                onClose: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { showFocusPanel = false }
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if selecting {
            selectionBar
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 0) {
            selectionAction("checkmark", label: "Concluir") {
                viewModel.complete(ids: selection)
                endSelection()
            }
            selectionAction("calendar", label: "Mover") {
                rescheduleSelection()
            }
            selectionAction("trash", label: "Excluir") {
                confirmingDelete = true
            }
            selectionAction("timer", label: "Foco") {
                startFocusPanel(title: focusTitleFromSelection())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.black, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .opacity(selection.isEmpty ? 0.5 : 1)
        .disabled(selection.isEmpty)
        .accessibilityIdentifier("tasks-selection-bar")
    }

    private func selectionAction(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tasks-selection-" + symbol)
    }

    private var focusSubtitle: String {
        if selection.isEmpty { return "Sessão livre" }
        return "\(selection.count) tarefa\(selection.count == 1 ? "" : "s") selecionada\(selection.count == 1 ? "" : "s")"
    }

    private func focusTitleFromSelection() -> String {
        let ordered = pending + completed
        if let first = ordered.first(where: { selection.contains($0.id) }), !first.title.isEmpty {
            return first.title
        }
        return "Foco"
    }

    private func startFocusPanel(title: String) {
        focusTitle = title
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            showFocusPanel = true
        }
    }

    private func startSession() {
        focus.start()
        showFocusPanel = false
        selecting = false
        runningFocus = true
    }

    private func endSelection() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            selecting = false
            selection = []
        }
    }

    // MARK: - FAB

    private var fab: some View {
        Button {
            composing = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.paperInk)
                .frame(width: 64, height: 64)
                .background(Color.primary, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 96)
        .accessibilityLabel("Nova tarefa")
        .accessibilityIdentifier("tasks-add")
    }
}

#Preview {
    TasksView()
}
