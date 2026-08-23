import SwiftUI

struct Snip: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var command: String

    init(id: UUID = UUID(), name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

enum SnipStore {
    static let seeds: [Snip] = [
        Snip(name: "dash", command: "dash --live"),
        Snip(name: "htop", command: "htop"),
        Snip(name: "cérebro", command: "cd ~/Gabriel && ls"),
        Snip(name: "sistema", command: "cd ~/Sistema && ls"),
        Snip(name: "tmux ls", command: "tmux ls"),
        Snip(name: "bridge log", command: "tail -f ~/Library/Logs/geobridge.log"),
    ]

    static func decode(_ raw: String) -> [Snip] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([Snip].self, from: data)
        else { return [] }
        return list
    }

    static func encode(_ snips: [Snip]) -> String {
        guard let data = try? JSONEncoder().encode(snips) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct SnipsSheet: View {
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("terminal.snips") private var snipsRaw = ""
    @AppStorage("terminal.snips.dashSeeded") private var dashSeeded = false
    @State private var showForm = false

    private var snips: [Snip] { SnipStore.decode(snipsRaw) }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(snips) { snip in
                    Menu {
                        Button { run(snip, newline: true) } label: {
                            Label("executar", systemImage: "play.fill")
                        }
                        Button { run(snip, newline: false) } label: {
                            Label("colar", systemImage: "doc.on.clipboard")
                        }
                    } label: {
                        row(snip)
                    }
                }
                .onDelete(perform: delete)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .glassSheet()
        .animation(.spring(response: 0.34, dampingFraction: 1), value: snips)
        .onAppear {
            if snipsRaw.isEmpty { snipsRaw = SnipStore.encode(SnipStore.seeds) }
            if !dashSeeded {
                dashSeeded = true
                let current = snips
                if !current.contains(where: { $0.command.hasPrefix("dash") }) {
                    snipsRaw = SnipStore.encode([Snip(name: "dash", command: "dash --live")] + current)
                }
            }
        }
        .sheet(isPresented: $showForm) {
            SnipFormView { snip in snipsRaw = SnipStore.encode(snips + [snip]) }
        }
    }

    private var header: some View {
        HStack {
            Text("snips")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Spacer()
            Button { showForm = true } label: {
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

    private func row(_ snip: Snip) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snip.name)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
            Text(snip.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func run(_ snip: Snip, newline: Bool) {
        onSend(newline ? snip.command + "\n" : snip.command)
        dismiss()
    }

    private func delete(at offsets: IndexSet) {
        var list = snips
        list.remove(atOffsets: offsets)
        snipsRaw = SnipStore.encode(list)
    }
}

struct SnipFormView: View {
    let onSave: (Snip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var command = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("novo snip")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            field("nome", text: $name)
            field("comando", text: $command)
            HStack(spacing: 10) {
                Button("cancelar") { dismiss() }
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                Spacer()
                Button("salvar") {
                    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(Snip(name: label.isEmpty ? trimmed : label, command: trimmed))
                    dismiss()
                }
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .font(.system(size: 14, weight: .medium, design: .monospaced))
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassSheet()
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(.primary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.slateCard, in: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }
}
