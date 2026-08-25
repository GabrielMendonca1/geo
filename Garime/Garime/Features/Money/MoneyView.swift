import SwiftUI

struct MoneyView: View {
    @StateObject private var store = MoneyStore.shared
    @State private var composing: MoneyKind?

    private var month: [MoneyEntry] {
        MoneyMath.entries(store.entries, inMonthOf: Date())
    }

    private var projection: MoneyProjection {
        MoneyMath.projection(for: store.entries)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    balanceCard
                    projectionCard
                    quickAdd
                    entriesList
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 110)
            }
            .dockScrollTracking()
            .background(Color.slateCanvas)
            .safeAreaInset(edge: .top) { header }
            .navigationBarHidden(true)
        }
        .sheet(item: $composing) { kind in
            MoneyEntrySheet(kind: kind) { entry in
                store.add(entry)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("dinheiro")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateText)
            Spacer()
            Text(MoneyFormat.month(Date()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.slateCanvas)
    }

    private var balanceCard: some View {
        let summary = MoneyMath.summary(of: month)
        return VStack(alignment: .leading, spacing: 8) {
            Text("saldo do mês")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Text(MoneyFormat.signed(summary.balance))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(summary.balance < 0 ? Color.red : Color.slateText)
            HStack(spacing: 14) {
                pill("entrou", MoneyFormat.brl(summary.income))
                pill("saiu", MoneyFormat.brl(summary.expense))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private var projectionCard: some View {
        let p = projection
        return VStack(alignment: .leading, spacing: 8) {
            Text("projeção · fim do mês")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Text(MoneyFormat.signed(p.projectedBalance))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(p.projectedBalance < 0 ? Color.red : Color.slateText)
            Text("recorrentes contam inteiro · o resto segue o ritmo dos dias já vividos")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            HStack(spacing: 14) {
                pill("entradas", MoneyFormat.brl(p.projectedIncome))
                pill("saídas", MoneyFormat.brl(p.projectedExpense))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private var quickAdd: some View {
        HStack(spacing: 10) {
            addButton(.expense, symbol: "arrow.up.right")
            addButton(.income, symbol: "arrow.down.left")
        }
    }

    private func addButton(_ kind: MoneyKind, symbol: String) -> some View {
        Button { composing = kind } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(kind.label)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Color.slateText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("money-add-\(kind.rawValue)")
    }

    @ViewBuilder
    private var entriesList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("lançamentos")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)

            if month.isEmpty {
                Text("nada lançado neste mês")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(month.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider().overlay(Color.slateStroke.opacity(0.35))
                        }
                        row(entry)
                    }
                }
                .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
            }
        }
    }

    private func row(_ entry: MoneyEntry) -> some View {
        HStack(spacing: 10) {
            Text(MoneyFormat.day(entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.slateText)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if entry.recurring {
                Image(systemName: "repeat")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.slateTextDim)
            }

            Text((entry.kind == .expense ? "-" : "+") + MoneyFormat.brl(entry.amount))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.kind == .expense ? Color.red : Color.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button("apagar", role: .destructive) { store.delete(entry) }
        }
    }

    private func pill(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateText)
        }
    }
}
