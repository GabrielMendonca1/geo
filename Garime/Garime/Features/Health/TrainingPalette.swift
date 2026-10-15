import SwiftUI
import UIKit

/// Paleta da aba treino: monocromática, na mesma linha da aba Dinheiro.
/// Ação e "agora" são o preto (branco no escuro); concluído é o mesmo tom;
/// atenção é o cinza secundário. Nada de cor de destaque.
enum TrainingPalette {
    /// Ação e "agora".
    static let accent = Color.primary

    /// Texto/ícone sobre o preenchimento de `accent`.
    static let onAccent = Color.paperInk

    /// Estado concluído.
    static let done = Color.primary

    /// Atenção suave (subir carga, avisos não bloqueantes).
    static let attention = Color.secondary

    /// Fundo de seleção "agora" — sempre usado com shape arredondado.
    static var accentSoft: Color { Color.primary.opacity(0.06) }
    static var doneSoft: Color { Color.primary.opacity(0.03) }
}

/// Pílula de ação (visual; o toque é de quem contém).
struct TrainingCTALabel: View {
    let title: String
    let systemImage: String
    var tint: Color = TrainingPalette.accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
        }
        .foregroundStyle(TrainingPalette.onAccent)
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity)
        .background(tint, in: Capsule())
    }
}

/// Estado visual de uma linha (exercício ou série).
enum TrainingRowState {
    case current
    case done
    case idle
}

/// Fundo de linha **sempre arredondado**.
struct TrainingRowBackground: View {
    let state: TrainingRowState
    var radius: CGFloat = PaperRadius.tile

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(fill)
            shape.stroke(stroke, lineWidth: 1)
        }
    }

    private var fill: Color {
        switch state {
        case .current: return TrainingPalette.accentSoft
        case .done: return .clear
        case .idle: return .clear
        }
    }

    private var stroke: Color {
        switch state {
        case .current: return Color.primary.opacity(0.9)
        case .done, .idle: return .clear
        }
    }
}

/// Texto/ícone do CTA da Home, isolado para teste.
enum WorkoutCTA {
    static func title(isRest: Bool, progress: SessionProgress) -> String {
        if isRest { return "abrir descanso" }
        if progress.isComplete { return "revisar treino" }
        return progress.setsDone > 0 ? "continuar treino" : "abrir treino"
    }

    static func icon(isRest: Bool, progress: SessionProgress) -> String {
        if progress.isComplete && !isRest { return "checkmark.circle.fill" }
        if isRest { return "figure.cooldown" }
        return progress.setsDone > 0 ? "play.circle.fill" : "figure.strengthtraining.traditional"
    }
}

/// Selo de estado com fundo arredondado.
struct TrainingBadge: View {
    let text: String
    let tint: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08), in: Capsule())
    }
}
