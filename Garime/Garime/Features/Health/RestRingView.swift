import SwiftUI

/// Formatação do anel de descanso, isolada para teste.
enum RestRing {
    /// "1m 12s" · "45s" · "0s".
    static func label(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let rest = clamped % 60
        if minutes == 0 { return "\(rest)s" }
        return "\(minutes)m \(rest)s"
    }

    /// Fração já cumprida do descanso (0…1).
    static func fraction(duration: Int, remaining: Int) -> Double {
        guard duration > 0 else { return 1 }
        let done = Double(duration - max(0, min(remaining, duration))) / Double(duration)
        return min(max(done, 0), 1)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Anel de descanso: trilho cinza, arco preto que fecha conforme o tempo passa,
/// tempo restante no centro e "Início / Meta" embaixo.
struct RestRingView: View {
    let state: RestTimerState
    let remaining: Int
    let onRestart: () -> Void
    let onSkip: () -> Void

    private var fraction: Double { RestRing.fraction(duration: state.duration, remaining: remaining) }
    private var started: Date { state.deadline.addingTimeInterval(-TimeInterval(state.duration)) }
    private var finished: Bool { remaining == 0 }

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: fraction)
                VStack(spacing: 6) {
                    Text(finished ? "Pode ir" : "Descansando há")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text(finished ? RestRing.label(state.duration) : RestRing.label(state.duration - remaining))
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                    Text(finished ? "descanso completo" : "faltam \(RestRing.label(remaining))")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)
            .padding(.top, 8)

            HStack {
                stamp("Início", RestRing.clock(started))
                Spacer()
                stamp("Meta", RestRing.clock(state.deadline))
            }
            .padding(.horizontal, 24)

            HStack(spacing: 10) {
                Button(action: onRestart) {
                    Text("Reiniciar")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.paperTile, in: Capsule())
                }
                Button(action: onSkip) {
                    Text(finished ? "Continuar" : "Pular")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.paperInk)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.primary, in: Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(finished ? "Descanso completo" : "Descanso, faltam \(RestRing.label(remaining))")
    }

    private func stamp(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
        }
    }
}

#Preview {
    RestRingView(
        state: RestTimerState(exerciseId: "x", day: "2026-09-16", setIndex: 0, duration: 90, deadline: Date().addingTimeInterval(50)),
        remaining: 50,
        onRestart: {},
        onSkip: {}
    )
    .padding()
    .background(Color.paperCanvas)
}
