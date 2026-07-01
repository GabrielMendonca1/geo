import SwiftUI

struct OnboardingPermissionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = PermissionRegistry.shared
    @State private var step: Int = 0
    @State private var requesting: Bool = false

    private static let completedKey = "ai.geo.onboarding.completed"
    private static let geoBlue = Color(red: 0/255, green: 85/255, blue: 255/255)

    private let order: [(id: String, icon: String)] = [
        ("accessibility", "accessibility"),
        ("inputMonitoring", "keyboard"),
        ("notifications", "bell.badge.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            footer
        }
        .frame(width: 520, height: 520)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear { registry.refreshAll() }
        .task(id: step) {
            while !Task.isCancelled {
                registry.refreshAll()
                if currentState.isGranted && !requesting {
                    advance()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            registry.refreshAll()
        }
    }

    private var currentEntry: (id: String, icon: String) { order[step] }
    private var currentPermission: (any Permission)? { registry.permission(for: currentEntry.id) }
    private var currentState: PermissionState { registry.states[currentEntry.id] ?? .unknown }

    private var header: some View {
        HStack {
            Text("Welcome to Geo")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Text("\(step + 1) of \(order.count)")
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            Button { finish() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.leading, 6)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private var content: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Self.geoBlue.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: currentEntry.icon)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(Self.geoBlue)
            }

            VStack(spacing: 8) {
                Text(currentPermission?.displayName ?? "")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                Text(currentPermission?.description ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            statusPill
        }
    }

    private var statusPill: some View {
        let (label, color): (String, Color) = {
            switch currentState {
            case .authorized: return ("Granted", .green)
            case .denied: return ("Denied", .orange)
            case .restricted: return ("Restricted", .orange)
            case .notDetermined: return ("Not requested", .white.opacity(0.5))
            case .unknown: return ("Unknown", .white.opacity(0.5))
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            primaryButton
            if !currentState.isGranted {
                Button { advance() } label: {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 32)
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch currentState {
        case .authorized:
            actionButton(title: "Continue", disabled: false) { advance() }
        default:
            actionButton(title: requesting ? "Opening Settings…" : "Open System Settings", disabled: requesting) {
                Task {
                    requesting = true
                    _ = await registry.request(currentEntry.id)
                    requesting = false
                }
            }
        }
    }

    private func actionButton(title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(disabled ? Self.geoBlue.opacity(0.4) : Self.geoBlue)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func advance() {
        if step + 1 < order.count {
            step += 1
            registry.refreshAll()
        } else {
            finish()
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismiss()
    }
}
