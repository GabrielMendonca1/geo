import SwiftUI
import UIKit

enum FocusMode: String, CaseIterable, Identifiable {
    case minimal
    case clock
    case stopwatch
    case timer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minimal: return "Mínimo"
        case .clock: return "Relógio"
        case .stopwatch: return "Cronômetro"
        case .timer: return "Timer"
        }
    }
}

/// Relógio da sessão de foco: um Timer de 1s alimenta `remaining`, `elapsed` e `now`.
@MainActor
final class FocusSessionModel: ObservableObject {
    @Published var mode: FocusMode = .timer
    @Published private(set) var duration: TimeInterval = 30 * 60
    @Published private(set) var remaining: TimeInterval = 30 * 60
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var now = Date()
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false

    private var ticker: Timer?

    static let step: TimeInterval = 5 * 60
    static let minimumDuration: TimeInterval = 5 * 60

    deinit { ticker?.invalidate() }

    func adjust(by steps: Int) {
        let next = max(Self.minimumDuration, duration + Double(steps) * Self.step)
        duration = next
        if !isRunning { remaining = next }
    }

    func start() {
        finished = false
        elapsed = 0
        remaining = duration
        now = Date()
        isRunning = true
        ticker?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        isRunning = false
    }

    private func tick() {
        now = Date()
        elapsed += 1
        guard mode == .timer, !finished else { return }
        remaining = max(0, remaining - 1)
        if remaining == 0 {
            finished = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func timeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Painel preto no rodapé da lista: escolhe modo, ajusta o timer e inicia a sessão.
struct FocusPanel: View {
    @ObservedObject var session: FocusSessionModel
    let subtitle: String
    let onStart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Menu {
                    ForEach(FocusMode.allCases) { mode in
                        Button {
                            session.mode = mode
                        } label: {
                            if mode == session.mode {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(session.mode.label)
                            .font(.system(size: 17, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                }
                .accessibilityIdentifier("tasks-focus-mode")

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fechar foco")
            }

            center
                .frame(maxWidth: .infinity)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)

            Button(action: onStart) {
                Text("Iniciar foco")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tasks-focus-start")
        }
        .padding(20)
        .background(Color.black, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    @ViewBuilder
    private var center: some View {
        switch session.mode {
        case .minimal:
            Color.clear.frame(height: 8)
        case .clock:
            Text(FocusSessionModel.timeOfDay(session.now))
                .font(.system(size: 56, weight: .light).monospacedDigit())
                .foregroundStyle(.white)
        case .stopwatch:
            Text("00:00")
                .font(.system(size: 56, weight: .light).monospacedDigit())
                .foregroundStyle(.white)
        case .timer:
            HStack(spacing: 24) {
                stepper("minus", enabled: session.duration > FocusSessionModel.minimumDuration) {
                    session.adjust(by: -1)
                }
                Text(FocusSessionModel.clock(session.duration))
                    .font(.system(size: 56, weight: .light).monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("tasks-focus-duration")
                stepper("plus", enabled: true) { session.adjust(by: 1) }
            }
        }
    }

    private func stepper(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(enabled ? 0.8 : 0.25))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Tela cheia preta da sessão em execução.
struct FocusSessionView: View {
    @ObservedObject var session: FocusSessionModel
    let title: String
    let onEnd: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var hintDismissed = false
    @State private var showsControls = false

    private var isPortrait: Bool { verticalSizeClass == .regular }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isPortrait && !hintDismissed {
                hint
            } else {
                content
            }
        }
        .statusBarHidden(true)
        .contentShape(Rectangle())
        .onTapGesture {
            if isPortrait && !hintDismissed {
                hintDismissed = true
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
            }
        }
    }

    private var hint: some View {
        VStack(spacing: 16) {
            Image(systemName: "rotate.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.white)
            Text("Sessão de foco funciona melhor em paisagem")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Gire o aparelho ou toque para continuar")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .accessibilityIdentifier("tasks-focus-hint")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 24)

            HStack(alignment: .bottom) {
                if showsControls {
                    Button {
                        onEnd()
                    } label: {
                        Text("Encerrar")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .accessibilityIdentifier("tasks-focus-end")
                }
                Spacer()
                timeReadout
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private var timeReadout: some View {
        switch session.mode {
        case .minimal:
            EmptyView()
        case .clock:
            readout(FocusSessionModel.timeOfDay(session.now))
        case .stopwatch:
            readout(FocusSessionModel.clock(session.elapsed))
        case .timer:
            if session.finished {
                Text("Concluído")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                readout(FocusSessionModel.clock(session.remaining))
            }
        }
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 56, weight: .light).monospacedDigit())
            .foregroundStyle(.white)
            .accessibilityIdentifier("tasks-focus-readout")
    }
}
