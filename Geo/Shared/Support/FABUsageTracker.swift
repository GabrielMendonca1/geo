import Foundation

protocol UsageTracker: Sendable {
    func track(_ actionLabel: String, in pane: String)
    func topActions(in pane: String, count: Int) -> [String]
    func sortedActionLabels(_ labels: [String], in pane: String) -> [String]
}

final class FABUsageTracker: ObservableObject, UsageTracker, @unchecked Sendable {
    private let defaults: UserDefaults
    private let usageKey = "fab.actionUsage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func trackAction(_ actionLabel: String, in pane: String) {
        var usage = getUsage(for: pane)
        usage[actionLabel, default: 0] += 1
        saveUsage(usage, for: pane)
    }

    func track(_ actionLabel: String, in pane: String) {
        trackAction(actionLabel, in: pane)
    }

    func getUsage(for pane: String) -> [String: Int] {
        let key = "\(usageKey).\(pane)"
        guard let data = defaults.data(forKey: key),
              let usage = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return usage
    }

    func getTopActions(in pane: String, count: Int = 2) -> [String] {
        getUsage(for: pane)
            .sorted { $0.value > $1.value }
            .prefix(count)
            .map { $0.key }
    }

    func topActions(in pane: String, count: Int = 2) -> [String] {
        getTopActions(in: pane, count: count)
    }

    func sortedActionLabels(_ labels: [String], in pane: String) -> [String] {
        let usage = getUsage(for: pane)
        return labels.sorted { lhs, rhs in
            let lhsUsage = usage[lhs, default: 0]
            let rhsUsage = usage[rhs, default: 0]

            if lhsUsage != rhsUsage {
                return lhsUsage > rhsUsage
            }

            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    func resetUsage(for pane: String) {
        defaults.removeObject(forKey: "\(usageKey).\(pane)")
    }

    private func saveUsage(_ usage: [String: Int], for pane: String) {
        let key = "\(usageKey).\(pane)"
        if let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: key)
        }
    }
}
