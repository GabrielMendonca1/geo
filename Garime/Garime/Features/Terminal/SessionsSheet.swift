import SwiftUI

struct SessionsSheet: View {
    let sessions: [String]
    let current: String
    let isDead: (String) -> Bool
    let onSelect: (String) -> Void
    let onSelectMac: () -> Void
    let onCreate: () -> Void
    let onDelete: (String) -> Void
    let onRefresh: () async -> Void

    @Environment(\.dismiss) private var dismiss

    private var vmSessions: [String] {
        sessions.filter { $0.hasPrefix("vm:") }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                Section {
                    ForEach(vmSessions, id: \.self) { name in
                        Button {
                            onSelect(name)
                            dismiss()
                        } label: {
                            row(
                                title: String(name.dropFirst(3)),
                                active: name == current,
                                dead: isDead(name)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: delete)
                } header: {
                    sectionTitle("vm")
                }
                Section {
                    Button {
                        onSelectMac()
                        dismiss()
                    } label: {
                        row(title: "mac", active: current.hasPrefix("mac"), dead: false)
                    }
                    .buttonStyle(.plain)
                } header: {
                    sectionTitle("mac")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 44)
        }
        .glassSheet()
        .animation(.spring(response: 0.34, dampingFraction: 1), value: sessions)
        .animation(.spring(response: 0.34, dampingFraction: 1), value: current)
        .task { await onRefresh() }
    }

    private var header: some View {
        HStack {
            Text("sessões")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
            Button {
                onCreate()
                dismiss()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(Color.slateCard, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func row(title: String, active: Bool, dead: Bool) -> some View {
        HStack(spacing: 10) {
            StatusDot(level: .live(!dead))
            Text(title)
                .font(.system(size: 14, weight: active ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opacity(dead ? 0.45 : 1)
            Spacer()
            if active {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            onDelete(vmSessions[index])
        }
    }
}
