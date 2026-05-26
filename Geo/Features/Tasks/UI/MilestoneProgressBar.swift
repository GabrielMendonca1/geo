import SwiftUI

struct MilestoneProgressBar: View {
    let progress: MilestoneProgress
    var compact: Bool = false

    private var fillStyle: AnyShapeStyle {
        if progress.isComplete {
            return AnyShapeStyle(Color.green)
        }
        return AnyShapeStyle(.tint)
    }

    private var clampedPercent: Double {
        min(max(progress.percent, 0), 1)
    }

    var body: some View {
        if compact {
            compactBar
        } else {
            VStack(alignment: .leading, spacing: 4) {
                fullBar
                if let label = labelText {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var compactBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(fillStyle)
                    .frame(width: max(0, geo.size.width * clampedPercent))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: progress.percent)
            }
        }
        .frame(height: 3)
    }

    private var fullBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Capsule(style: .continuous)
                    .fill(fillStyle)
                    .frame(width: max(0, geo.size.width * clampedPercent))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: progress.percent)
            }
        }
        .frame(height: 6)
    }

    private var labelText: String? {
        let checkboxes = progress.checkboxStats.total
        let subtasks = progress.subtaskTotal
        let pct = Int((clampedPercent * 100).rounded())

        if checkboxes > 0 && subtasks > 0 {
            let boxLabel = checkboxes == 1 ? "1 box" : "\(checkboxes) boxes"
            let taskLabel = subtasks == 1 ? "1 task" : "\(subtasks) tasks"
            return "\(boxLabel) + \(taskLabel) \u{00B7} \(pct)%"
        }
        if checkboxes > 0 {
            return "\(progress.checkboxStats.checked)/\(checkboxes) \u{00B7} \(pct)%"
        }
        if subtasks > 0 {
            let word = subtasks == 1 ? "task" : "tasks"
            return "\(progress.subtaskCompleted)/\(subtasks) \(word) \u{00B7} \(pct)%"
        }
        return nil
    }
}
