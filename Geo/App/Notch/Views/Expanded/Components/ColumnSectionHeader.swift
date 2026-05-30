import SwiftUI

struct NotchChip: View {
    var title: String? = nil
    var systemImage: String? = nil
    var count: Int? = nil
    var isActive: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                if let title {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                }
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isActive ? Color.black.opacity(0.4) : Color.white.opacity(0.35))
                }
            }
            .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.6))
            .padding(.horizontal, title == nil ? 9 : 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(isActive ? Color.white : Color.white.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
