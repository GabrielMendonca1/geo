import SwiftUI

struct MoneyEntrySheet: View {
    let kind: MoneyKind
    let onSave: (MoneyEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rawAmount = ""
    @State private var category = ""
    @State private var note = ""
    @State private var date = Date()
    @State private var recurring = false
    @FocusState private var amountFocused: Bool

    private var amount: Decimal? { MoneyAmount.parse(rawAmount) }
    private var canSave: Bool { amount != nil && !category.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    amountField
                    categories
                    noteField
                    options
                }
                .padding(16)
            }
            .background(Color.slateCanvas)
            .navigationTitle(kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("salvar") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            category = MoneyCategories.options(for: kind).first ?? ""
            amountFocused = true
        }
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("valor")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            TextField("0,00", text: $rawAmount)
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateText)
                .accessibilityIdentifier("money-amount")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private var categories: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("categoria")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(MoneyCategories.options(for: kind), id: \.self) { option in
                    Button { category = option } label: {
                        Text(option)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(category == option ? Color.slateCanvas : Color.slateText)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(
                                RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                                    .fill(category == option ? Color.slateText : Color.slateText.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("nota")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            TextField("opcional", text: $note)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.slateText)
                .padding(12)
                .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("data", selection: $date, displayedComponents: .date)
                .font(.system(size: 12, design: .monospaced))
            Toggle("repete todo mês", isOn: $recurring)
                .font(.system(size: 12, design: .monospaced))
        }
        .foregroundStyle(Color.slateText)
        .padding(14)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func save() {
        guard let amount else { return }
        onSave(
            MoneyEntry(
                date: date,
                kind: kind,
                amount: amount,
                category: category,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                recurring: recurring
            )
        )
        dismiss()
    }
}
