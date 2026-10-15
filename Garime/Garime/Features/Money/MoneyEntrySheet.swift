import SwiftUI

struct MoneyEntrySheet: View {
    let kind: MoneyKind
    let onSave: (MoneyEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = MoneyStore.shared
    @AppStorage("moneyWorkspace") private var workspace = MoneyWorkspaces.personal
    @State private var selectedKind: MoneyKind
    @State private var rawAmount = ""
    @State private var category = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var recurring = false
    @FocusState private var amountFocused: Bool

    init(kind: MoneyKind, onSave: @escaping (MoneyEntry) -> Void) {
        self.kind = kind
        self.onSave = onSave
        _selectedKind = State(initialValue: kind)
    }

    private var amount: Decimal? { MoneyAmount.parse(rawAmount) }
    private var canSave: Bool { amount != nil && !category.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    kindPicker
                    amountField
                    categories
                    noteField
                    options
                    if store.workspaces.count > 1 { workspacePicker }
                    saveButton
                }
                .padding(16)
            }
            .background(Color.paperCanvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Novo lançamento")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .foregroundStyle(Color.primary)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            category = MoneyCategories.options(for: selectedKind).first ?? ""
            amountFocused = true
        }
        .onChange(of: selectedKind) { _, newValue in
            let options = MoneyCategories.options(for: newValue)
            if !options.contains(category) { category = options.first ?? "" }
        }
    }

    // MARK: - Tipo

    private var kindPicker: some View {
        HStack(spacing: 4) {
            segment(title: "Gasto", kind: .expense)
            segment(title: "Entrada", kind: .income)
        }
        .padding(4)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.tile + 4, style: .continuous))
    }

    private func segment(title: String, kind option: MoneyKind) -> some View {
        let selected = selectedKind == option
        return Button {
            selectedKind = option
        } label: {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selected ? Color.paperInk : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(
                    selected ? Color.paperFilled : Color.clear,
                    in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("money-kind-" + option.rawValue)
    }

    // MARK: - Valor

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Valor")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("R$")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("0,00", text: $rawAmount)
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .accessibilityIdentifier("money-amount")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    // MARK: - Categorias

    private var categories: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Categoria")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MoneyCategories.options(for: selectedKind), id: \.self) { option in
                        chip(option)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func chip(_ option: String) -> some View {
        let selected = category == option
        return Button {
            category = option
        } label: {
            Text(option.prefix(1).uppercased() + option.dropFirst())
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Color.paperInk : Color.primary)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(
                    selected ? Color.paperFilled : Color.paperCard,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Nota e opções

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nota")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            TextField("Opcional", text: $note)
                .font(.system(size: 17))
                .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    private var options: some View {
        VStack(spacing: 0) {
            DatePicker("Data", selection: $date, displayedComponents: .date)
                .font(.system(size: 17))
                .tint(Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider().padding(.leading, 16)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Repete todo mês", isOn: $recurring)
                    .font(.system(size: 17))
                    .tint(Color.primary)
                if recurring {
                    Text("Aparece no calendário todo mês neste dia")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .foregroundStyle(Color.primary)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    /// Só informa para onde o lançamento vai: quem decide o espaço é a aba.
    private var workspacePicker: some View {
        HStack {
            Text("Espaço")
                .font(.system(size: 17))
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            Text(workspace)
                .font(.system(size: 15))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.paperTile, in: Capsule())
                .accessibilityIdentifier("money-entry-workspace")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    private var saveButton: some View {
        Button { save() } label: {
            Text("Salvar")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.paperInk)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(
                    Color.paperFilled.opacity(canSave ? 1 : 0.35),
                    in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
        .accessibilityIdentifier("money-save")
    }

    private func save() {
        guard let amount else { return }
        onSave(
            MoneyEntry(
                date: date,
                kind: selectedKind,
                amount: amount,
                category: category,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                recurring: recurring
            )
        )
        dismiss()
    }
}
