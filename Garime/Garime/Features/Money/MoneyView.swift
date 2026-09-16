import SwiftUI
import UniformTypeIdentifiers

struct MoneyView: View {
    @StateObject private var store = MoneyStore.shared
    @AppStorage("moneyScope") private var scopeRaw = MoneyScope.expense.rawValue
    @AppStorage("moneyWorkspace") private var workspace = MoneyWorkspaces.personal
    @State private var namingWorkspace = false
    @State private var newWorkspaceName = ""
    @State private var deletingWorkspace = false
    @State private var composing: MoneyKind?
    @State private var choosingKind = false
    @State private var importing = false
    @State private var importMessage: String?
    @State private var searching = false
    @State private var query = ""
    @State private var showSettings = false
    @FocusState private var searchFocused: Bool

    private var scope: MoneyScope {
        MoneyScope(rawValue: scopeRaw) ?? .expense
    }

    private var workspaceEntries: [MoneyEntry] {
        store.entries(in: workspace)
    }

    private var week: MoneyWeek {
        MoneyOverview.week(workspaceEntries, scope: scope)
    }

    private var groups: [MoneyOverview.DayGroup] {
        MoneyOverview.groups(workspaceEntries, scope: scope, query: query)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        totalCard
                            .padding(.top, 8)
                        if groups.isEmpty {
                            emptyState
                                .padding(.top, 28)
                        } else {
                            ForEach(groups) { group in
                                section(group)
                                    .padding(.top, 28)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 150)
                }
                .dockScrollTracking()
                .scrollDismissesKeyboard(.immediately)
                fab
            }
            .background(Color.moneyCanvas)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .navigationBarHidden(true)
        }
        .sheet(item: $composing) { kind in
            MoneyEntrySheet(kind: kind) { entry in
                var tagged = entry
                tagged.workspace = workspace
                store.add(tagged)
            }
        }
        .alert("Novo espaço", isPresented: $namingWorkspace) {
            TextField("Ex.: Minha empresa", text: $newWorkspaceName)
            Button("Criar") {
                if let created = store.addWorkspace(newWorkspaceName) {
                    workspace = created
                }
                newWorkspaceName = ""
            }
            Button("Cancelar", role: .cancel) { newWorkspaceName = "" }
        } message: {
            Text("Pessoal, trabalho, uma empresa: cada espaço tem seus próprios lançamentos.")
        }
        .confirmationDialog(
            "Apagar \"\(workspace)\"?",
            isPresented: $deletingWorkspace,
            titleVisibility: .visible
        ) {
            Button("Apagar espaço", role: .destructive) {
                let doomed = workspace
                workspace = MoneyWorkspaces.personal
                store.deleteWorkspace(doomed)
            }
        } message: {
            Text("Os lançamentos dele passam para Pessoal.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog("Novo lançamento", isPresented: $choosingKind, titleVisibility: .hidden) {
            Button("Gasto") { composing = .expense }
            Button("Entrada") { composing = .income }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: MoneyView.statementTypes,
            allowsMultipleSelection: false
        ) { result in
            importStatement(result)
        }
        .alert("Extrato", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                scopeMenu
                Spacer()
                actions
            }
            if searching {
                searchField
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Color.moneyCanvas)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: searching)
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(store.workspaces, id: \.self) { option in
                Button {
                    workspace = option
                } label: {
                    if option == workspace {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
            Divider()
            Button {
                namingWorkspace = true
            } label: {
                Label("Novo espaço…", systemImage: "plus")
            }
            if workspace != MoneyWorkspaces.personal {
                Button(role: .destructive) {
                    deletingWorkspace = true
                } label: {
                    Label("Apagar \"\(workspace)\"", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(workspace)
                    .lineLimit(1)
                    .font(.system(size: 17, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.moneyCard, in: Capsule())
        }
        .accessibilityIdentifier("money-workspace")
    }

    private var actions: some View {
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
            .accessibilityIdentifier("money-search")

            Menu {
                Picker("Mostrar", selection: $scopeRaw) {
                    ForEach(MoneyScope.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                Divider()
                Button {
                    importing = true
                } label: {
                    Label("Importar extrato OFX", systemImage: "tray.and.arrow.down")
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Filtros")
            .accessibilityIdentifier("money-import")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Ajustes")
            .accessibilityIdentifier("money-settings")
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 4)
        .background(Color.moneyCard, in: Capsule())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar lançamento", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("money-search-field")
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
        .background(Color.moneyCard, in: Capsule())
    }

    // MARK: - Total + gráfico

    private var totalCard: some View {
        let week = week
        return VStack(alignment: .leading, spacing: 0) {
            Text(scope.totalLabel)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text(MoneyFormat.signed(week.total))
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Color.primary)
                .padding(.top, 6)
                .accessibilityIdentifier("money-total")
            MoneyWeekChart(week: week)
                .frame(height: 220)
                .padding(.top, 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.moneyCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - Listas

    private func section(_ group: MoneyOverview.DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(group.title)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            VStack(spacing: 0) {
                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 74)
                            .padding(.trailing, 20)
                    }
                    row(entry)
                }
            }
            .background(Color.moneyCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func row(_ entry: MoneyEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: MoneyOverview.symbol(for: entry))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .background(Color.moneyTile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(MoneyOverview.title(for: entry))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(MoneyOverview.subtitle(for: entry))
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if entry.recurring {
                Image(systemName: "repeat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(amountText(entry))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Apagar", role: .destructive) { store.delete(entry) }
        }
    }

    private func amountText(_ entry: MoneyEntry) -> String {
        let value = MoneyFormat.brl(entry.amount)
        guard scope == .all else { return value }
        return (entry.kind == .income ? "+" : "-") + value
    }

    private var emptyState: some View {
        Text(query.isEmpty ? "Nada lançado ainda" : "Nada encontrado")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.moneyCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // MARK: - FAB

    private var fab: some View {
        Button {
            switch scope {
            case .expense: composing = .expense
            case .income: composing = .income
            case .all: choosingKind = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.moneyCanvasInverse)
                .frame(width: 64, height: 64)
                .background(Color.primary, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 96)
        .accessibilityLabel("Novo lançamento")
        .accessibilityIdentifier("money-add")
    }

    // MARK: - Importação

    static var statementTypes: [UTType] {
        var types: [UTType] = [.data]
        if let ofx = UTType(filenameExtension: "ofx") { types.insert(ofx, at: 0) }
        return types
    }

    private func importStatement(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            importMessage = "Não deu pra abrir o arquivo"
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            importMessage = "Não deu pra ler o arquivo"
            return
        }
        let transactions = OFXParser.parse(data)
        var incoming = MoneyImport.entries(from: transactions)
        for index in incoming.indices { incoming[index].workspace = workspace }
        let outcome = store.importEntries(incoming)
        importMessage = outcome.message
    }
}

/// Barras pretas por dia da semana, linhas de grade com eixo à direita.
struct MoneyWeekChart: View {
    let week: MoneyWeek

    private let axisWidth: CGFloat = 36
    private let labelHeight: CGFloat = 22

    var body: some View {
        let ticks = week.axisTicks
        let top = week.axisMax
        GeometryReader { proxy in
            let plotWidth = proxy.size.width - axisWidth
            let plotHeight = proxy.size.height - labelHeight
            let slot = plotWidth / CGFloat(max(week.days.count, 1))
            let barWidth = min(slot * 0.68, 56)

            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let y = plotHeight - plotHeight * ratio(tick, top)
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: plotWidth, height: 1)
                        .offset(y: y)
                    Text(MoneyWeekChart.tickLabel(tick))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: axisWidth - 6, alignment: .trailing)
                        .offset(x: plotWidth + 6, y: y - 8)
                }

                ForEach(Array(week.days.enumerated()), id: \.element.id) { index, day in
                    let height = plotHeight * ratio(abs(day.total), top)
                    let x = slot * CGFloat(index) + (slot - barWidth) / 2
                    if height > 0 {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 8, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 8,
                            style: .continuous
                        )
                        .fill(Color.primary)
                        .frame(width: barWidth, height: height)
                        .offset(x: x, y: plotHeight - height)
                    }
                    Text(day.label)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: slot)
                        .offset(x: slot * CGFloat(index), y: plotHeight + 8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gráfico da semana")
        .accessibilityValue(MoneyFormat.brl(week.total))
    }

    private func ratio(_ value: Decimal, _ top: Decimal) -> CGFloat {
        guard top > 0 else { return 0 }
        let fraction = (value / top) as NSDecimalNumber
        return min(max(CGFloat(fraction.doubleValue), 0), 1)
    }

    static func tickLabel(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        if value >= 1000 {
            let thousands = number.doubleValue / 1000
            return thousands == thousands.rounded() ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
        }
        return "\(number.intValue)"
    }
}

private extension Color {
    static let moneyCanvas = Color(uiColor: .systemGroupedBackground)
    static let moneyCard = Color(uiColor: .secondarySystemGroupedBackground)
    static let moneyTile = Color(uiColor: .tertiarySystemGroupedBackground)
    static let moneyCanvasInverse = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    })
}
