import SwiftUI
import UIKit

/// Paleta local da aba treino. Não toca no tema global (AirTheme): só define as
/// poucas cores de ação e estado que a UX de treino precisa, com contraste
/// próprio para claro e escuro.
enum TrainingPalette {
    /// Ação e "agora": ciano/teal.
    static let accent = Color(
        UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.22, green: 0.84, blue: 0.82, alpha: 1)
            : UIColor(red: 0.00, green: 0.44, blue: 0.48, alpha: 1)
        }
    )

    /// Texto/ícone sobre o preenchimento de `accent`.
    static let onAccent = Color(
        UIColor { $0.userInterfaceStyle == .dark ? UIColor.black : UIColor.white }
    )

    /// Estado concluído: verde.
    static let done = Color(
        UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1)
            : UIColor(red: 0.06, green: 0.51, blue: 0.27, alpha: 1)
        }
    )

    /// Atenção suave (subir carga, avisos não bloqueantes): âmbar.
    static let attention = Color(
        UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 0.99, green: 0.75, blue: 0.29, alpha: 1)
            : UIColor(red: 0.60, green: 0.40, blue: 0.00, alpha: 1)
        }
    )

    /// Fundo de seleção "agora" — sempre usado com shape arredondado.
    static var accentSoft: Color { accent.opacity(0.22) }
    static var doneSoft: Color { done.opacity(0.18) }
}

/// Pílula colorida de ação (visual; o toque é de quem contém).
struct TrainingCTALabel: View {
    let title: String
    let systemImage: String
    var tint: Color = TrainingPalette.accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(TrainingPalette.onAccent)
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
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

/// Fundo de linha **sempre arredondado**: o estado selecionado nunca desenha um
/// retângulo quadrado por cima de um cartão de cantos redondos.
struct TrainingRowBackground: View {
    let state: TrainingRowState
    var radius: CGFloat = SlateRadius.cell

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
        case .done: return TrainingPalette.doneSoft
        case .idle: return Color.slateInk(0.04)
        }
    }

    private var stroke: Color {
        switch state {
        case .current: return TrainingPalette.accent.opacity(0.55)
        case .done: return TrainingPalette.done.opacity(0.35)
        case .idle: return .clear
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

/// Selo de estado com fundo arredondado (nunca um retângulo vazando a borda).
struct TrainingBadge: View {
    let text: String
    let tint: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.16), in: Capsule())
    }
}
