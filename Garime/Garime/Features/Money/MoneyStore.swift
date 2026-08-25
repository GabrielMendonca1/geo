import Foundation
import os

/// Guarda os lançamentos no próprio aparelho: funciona na academia,
/// no metrô, fora do tailnet. Sincronizar com a VM é assunto de v2.
@MainActor
final class MoneyStore: ObservableObject {
    @Published private(set) var entries: [MoneyEntry] = []

    static let shared = MoneyStore()

    private let logger = Logger(subsystem: "com.gabrielmendonca.garime", category: "MoneyStore")
    private let fileURL: URL?

    init(fileURL: URL? = MoneyStore.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    nonisolated static var defaultURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Garime", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("money.json")
    }

    func add(_ entry: MoneyEntry) {
        entries.append(entry)
        entries.sort { $0.date > $1.date }
        save()
    }

    func delete(_ entry: MoneyEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func delete(at offsets: IndexSet, in visible: [MoneyEntry]) {
        for index in offsets where visible.indices.contains(index) {
            entries.removeAll { $0.id == visible[index].id }
        }
        save()
    }

    func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([MoneyEntry].self, from: data).sorted { $0.date > $1.date }
        } catch {
            logger.warning("Failed to read money entries: \(error.localizedDescription)")
        }
    }

    func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            logger.warning("Failed to persist money entries: \(error.localizedDescription)")
        }
    }
}

enum MoneyCategories {
    static let expense = ["mercado", "comida", "transporte", "casa", "saúde", "academia", "lazer", "assinatura", "outro"]
    static let income = ["salário", "freela", "reembolso", "investimento", "outro"]

    static func options(for kind: MoneyKind) -> [String] {
        kind == .income ? income : expense
    }
}
