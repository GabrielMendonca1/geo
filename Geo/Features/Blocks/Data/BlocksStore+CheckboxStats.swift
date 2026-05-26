import Foundation

struct CheckboxStats: Hashable, Sendable {
    let total: Int
    let checked: Int

    var percent: Double {
        total == 0 ? 0 : Double(checked) / Double(total)
    }

    var isComplete: Bool {
        total > 0 && checked == total
    }

    static let empty = CheckboxStats(total: 0, checked: 0)
}

extension BlocksStore {
    func checkboxStats(for blockId: String) -> CheckboxStats {
        let items = checkboxes(in: blockId)
        guard !items.isEmpty else { return .empty }
        let checked = items.filter(\.checked).count
        return CheckboxStats(total: items.count, checked: checked)
    }
}
