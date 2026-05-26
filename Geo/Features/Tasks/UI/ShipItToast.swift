import SwiftUI

struct ShipItToast: View {
    @EnvironmentObject var watcher: MilestoneShipWatcher

    var body: some View {
        ZStack {
            if let ship = watcher.pendingShip {
                card(for: ship)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: watcher.pendingShip)
    }

    private func card(for ship: MilestoneShipWatcher.PendingShip) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to ship?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(ship.milestone.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button("Later") {
                    watcher.snooze()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Mark shipped") {
                    watcher.shipIt()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 16, x: 0, y: 6)
    }
}
