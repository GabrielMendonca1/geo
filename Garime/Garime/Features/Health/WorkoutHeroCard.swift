import SwiftUI

/// Nomes pt-BR dos grupos musculares do mapa (mesmos slugs do SVG — o
/// mapeamento de paths não muda, isto é só rótulo de leitura).
enum MuscleLabel {
    private static let table: [String: String] = [
        "abs": "abdômen",
        "adductors": "adutores",
        "ankles": "tornozelos",
        "biceps": "bíceps",
        "calves": "panturrilhas",
        "chest": "peito",
        "deltoids": "ombros",
        "forearm": "antebraço",
        "gluteal": "glúteos",
        "hamstring": "posterior",
        "lower-back": "lombar",
        "neck": "pescoço",
        "obliques": "oblíquos",
        "quadriceps": "quadríceps",
        "tibialis": "tibial",
        "trapezius": "trapézio",
        "triceps": "tríceps",
        "upper-back": "costas",
    ]

    static func text(_ slug: String) -> String {
        table[slug] ?? slug.replacingOccurrences(of: "-", with: " ")
    }

    /// Lista curta e estável para o cartão de hoje.
    static func list(_ slugs: Set<String>, limit: Int = 4) -> [String] {
        let names = Set(slugs.map(text)).sorted()
        return Array(names.prefix(limit))
    }
}

/// Protagonista da Home de treino: modelo muscular grande, destaques do dia e
/// um CTA colorido. O cartão inteiro é o toque que abre a tela dedicada.
struct WorkoutHeroCard: View {
    let sessionName: String
    let highlighted: Set<String>
    let isRest: Bool
    let progress: SessionProgress
    let currentName: String?
    let restLabel: String?
    let action: () -> Void

    private var ctaTitle: String { WorkoutCTA.title(isRest: isRest, progress: progress) }

    private var ctaIcon: String { WorkoutCTA.icon(isRest: isRest, progress: progress) }

    private var ctaTint: Color {
        progress.isComplete && !isRest ? TrainingPalette.done : TrainingPalette.accent
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                BodyMapView(highlighted: highlighted)
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical) { height, _ in
                        min(440, max(360, height * 0.46))
                    }
                    // O mapa é decorativo: quem recebe o toque é o cartão.
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(sessionName.lowercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                        .lineLimit(1)

                    if !highlighted.isEmpty {
                        highlightsRow
                    }

                    if let restLabel {
                        TrainingBadge(text: "descanso \(restLabel)", tint: TrainingPalette.accent, systemImage: "timer")
                    }

                    if !isRest, progress.setsTarget > 0 {
                        ProgressBar(fraction: progress.fraction)
                        Text("\(progress.setsDone)/\(progress.setsTarget) séries · \(progress.exercisesDone)/\(progress.exercisesTarget) exercícios")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.slateTextFaint)
                    }

                    if let currentName, !progress.isComplete {
                        Text("agora · \(currentName.lowercased())")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TrainingPalette.accent)
                            .lineLimit(1)
                    }
                }

                TrainingCTALabel(title: ctaTitle, systemImage: ctaIcon, tint: ctaTint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Treino de hoje: \(sessionName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Abre a tela do treino")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: String {
        if isRest { return "dia de descanso ativo" }
        var parts = ["\(progress.setsDone) de \(progress.setsTarget) séries"]
        if let currentName, !progress.isComplete { parts.append("agora \(currentName)") }
        return parts.joined(separator: ", ")
    }

    private var highlightsRow: some View {
        HStack(spacing: 6) {
            ForEach(MuscleLabel.list(highlighted, limit: 3), id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.slateText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(BodyMapPalette.highlight.opacity(0.18), in: Capsule())
            }
            if highlighted.count > 3 {
                Text("+\(highlighted.count - 3)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .fixedSize()
            }
        }
    }
}

#Preview {
    ScrollView {
        WorkoutHeroCard(
            sessionName: "a · pernas",
            highlighted: ["quadriceps", "gluteal", "hamstring"],
            isRest: false,
            progress: SessionProgress(setsDone: 4, setsTarget: 12, exercisesDone: 1, exercisesTarget: 4),
            currentName: "agachamento livre",
            restLabel: nil,
            action: {}
        )
        .padding(16)
    }
    .background(Color.slateCanvas)
}
