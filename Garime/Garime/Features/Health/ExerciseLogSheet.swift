import SwiftUI

private struct SetRow: Identifiable {
    let id = UUID()
    var reps: String = ""
    var kg: String = ""
    var committed: Bool = false
    /// Existing server values are preserved verbatim, not re-parsed as new input.
    var original: VitalsLogSet?
}

struct ExerciseLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: VitalsExercise
    let logged: VitalsLogExercise?
    let lastWeight: Double?
    /// Leitura da foto: entra como sugestão pré-preenchida, nunca como log.
    var reading: TrainingVisionReading?
    @ObservedObject var session: WorkoutSessionModel
    let onSave: ([VitalsLogSet]) async throws -> Void

    @State private var rows: [SetRow] = []
    @State private var busyIndex: Int?
    @State private var preparedDay: String?
    @State private var failure: String?
    @State private var retry: RetryAction?
    @State private var rowError: [Int: String] = [:]
    @FocusState private var focused: FocusField?

    private enum FocusField: Hashable {
        case reps(Int)
        case kg(Int)
    }

    enum RetryAction: Equatable {
        case complete(Int)
        case undoLast
    }

    private var isTrackable: Bool { WorkoutProgress.isTrackable(exercise) }
    private var committedCount: Int { rows.filter(\.committed).count }
    private var progress: ExerciseProgress {
        WorkoutProgress.exercise(prescribed: exercise.sets, loggedSets: committedCount)
    }
    private var currentIndex: Int? {
        rows.firstIndex(where: { !$0.committed })
    }
    private var restPrescription: String {
        let seconds = RestTimerRules.duration(restSec: exercise.restSec)
        return "Descanso \(seconds)s" + ((exercise.restSec ?? 0) > 0 ? "" : " (padrão)")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let rest = session.rest {
                        RestRingView(
                            state: rest,
                            remaining: session.remaining,
                            onRestart: { session.restartRest() },
                            onSkip: { session.skipRest() }
                        )
                    } else {
                        headline
                    }

                    if let reading {
                        visionBanner(reading)
                    }

                    if isTrackable {
                        VStack(spacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, _ in
                                setRow(index: index)
                            }
                        }
                        .padding(12)
                        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))

                        hint
                    } else {
                        durationCard
                    }

                    if let failure {
                        failureBanner(failure)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .background(Color.paperCanvas)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(exercise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fechar") { persistDraft(); dismiss() }
                        .disabled(isBusy)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("OK") { focused = nil }
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .presentationDetents([.large])
        .tint(Color.primary)
        .onAppear(perform: prepare)
        .onDisappear(perform: persistDraft)
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool { busyIndex != nil }

    // MARK: - Cabeçalho

    private var headline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                BodyMapView(highlighted: Set(exercise.muscles))
                    .padding(8)
                    .frame(width: 96, height: 96)
                    .background(Color.paperTile, in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(MuscleNames.line(exercise.muscles))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(VitalsFormat.prescription(exercise.sets, doseType: exercise.doseType))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(restPrescription)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if let lastWeight {
                        Text("Última: \(VitalsFormat.kg(lastWeight))")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if isTrackable {
                HStack {
                    Text("Séries")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(progress.done) de \(progress.target)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                ProgressBar(fraction: progress.fraction)
            }
        }
        .padding(16)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    // MARK: - Linhas de série

    @ViewBuilder
    private func setRow(index: Int) -> some View {
        let row = rows[safe: index] ?? SetRow()
        let isCurrent = currentIndex == index
        let target = WorkoutProgress.suggestedReps(prescribed: exercise.sets, index: index)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.paperCard : Color.primary)
                    .frame(width: 28, height: 28)
                    .background(isCurrent ? Color.primary : Color.paperTile, in: Circle())
                    .opacity(row.committed || isCurrent ? 1 : 0.5)

                field(
                    text: repsBinding(index: index),
                    prompt: target.map { "\($0)" } ?? "reps",
                    suffix: "reps",
                    width: 62,
                    keyboard: .numberPad,
                    focus: .reps(index),
                    enabled: !row.committed && !isBusy
                )

                field(
                    text: kgBinding(index: index),
                    prompt: "0",
                    suffix: "kg",
                    width: 76,
                    keyboard: .decimalPad,
                    focus: .kg(index),
                    enabled: !row.committed && !isBusy
                )

                Spacer(minLength: 4)

                action(index: index, row: row)
            }

            if let message = rowError[index] {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Série \(index + 1)\(row.committed ? ", concluída" : (isCurrent ? ", atual" : ""))")
    }

    @ViewBuilder
    private func action(index: Int, row: SetRow) -> some View {
        if row.committed {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("série concluída")
                if index == committedCount - 1 {
                    Button("Desfazer") { undoLast() }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minHeight: 44)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                }
            }
        } else if currentIndex == index {
            Button {
                complete(index: index)
            } label: {
                Group {
                    if busyIndex == index {
                        ProgressView().tint(Color.paperCard).scaleEffect(0.8)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                .foregroundStyle(Color.paperCard)
                .frame(width: 44, height: 44)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Concluir série \(index + 1)")
            .disabled(isBusy)
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func field(
        text: Binding<String>,
        prompt: String,
        suffix: String,
        width: CGFloat,
        keyboard: UIKeyboardType,
        focus: FocusField,
        enabled: Bool
    ) -> some View {
        HStack(spacing: 3) {
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(.tertiary))
                .keyboardType(keyboard)
                .accessibilityLabel(suffix == "kg" ? "Peso em quilogramas" : "Repetições")
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .focused($focused, equals: focus)
                .disabled(!enabled)
            Text(suffix)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: width)
        .frame(height: 44)
        .padding(.horizontal, 10)
        .background(Color.paperTile, in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))
        .opacity(enabled ? 1 : 0.6)
    }

    private var hint: some View {
        Text("0 kg = peso corporal. O botão ✓ salva a série e inicia o descanso.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var durationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exercício por tempo")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text("O registro de séries aceita apenas repetições. Acompanhe o tempo no relógio e use a nota do dia.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button {
                session.startRest(exerciseId: exercise.id, setIndex: 0, restSec: exercise.restSec)
            } label: {
                Text("Iniciar descanso")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.paperCard)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    private func failureBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Não salvou: \(message)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Seus números continuam aqui.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if retry != nil {
                Button("Tentar de novo") { performRetry() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .buttonStyle(.plain)
                    .disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    @ViewBuilder
    private func visionBanner(_ reading: TrainingVisionReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                Text("Leitura da foto — confira antes de concluir")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            Text(VisionBannerText.summary(reading))
                .font(.system(size: 14))
                .foregroundStyle(.primary)

            if !reading.note.isEmpty {
                Text(reading.note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    // MARK: - Bindings

    private func repsBinding(index: Int) -> Binding<String> {
        Binding(
            get: { rows[safe: index]?.reps ?? "" },
            set: { value in
                guard rows.indices.contains(index), !rows[index].committed else { return }
                rows[index].reps = WorkoutInput.sanitizeRepsText(value)
                rowError[index] = nil
                persistDraft()
            }
        )
    }

    private func kgBinding(index: Int) -> Binding<String> {
        Binding(
            get: { rows[safe: index]?.kg ?? "" },
            set: { value in
                guard rows.indices.contains(index), !rows[index].committed else { return }
                rows[index].kg = WorkoutInput.sanitizeWeightText(value)
                rowError[index] = nil
                persistDraft()
            }
        )
    }

    // MARK: - Estado

    private func prepare() {
        guard rows.isEmpty else { return }
        preparedDay = session.day
        let suggestion = WorkoutInput.weightText(reading?.weightKg ?? lastWeight)
        let loggedSets = logged?.sets ?? []
        let count = max(max(exercise.sets.count, loggedSets.count), 1)
        let drafts = session.draft(for: exercise.id)

        rows = (0..<count).map { index in
            if let set = loggedSets[safe: index] {
                let formatted = WorkoutInput.weightText(set.kg)
                return SetRow(reps: "\(set.reps)", kg: formatted.isEmpty ? String(set.kg) : formatted,
                              committed: true, original: set)
            }
            let draft = drafts[safe: index]
            return SetRow(
                reps: draft?.reps ?? "",
                kg: draft?.kg.isEmpty == false ? (draft?.kg ?? "") : suggestion,
                committed: false
            )
        }
    }

    private func persistDraft() {
        guard let preparedDay, !preparedDay.isEmpty, preparedDay == session.day else { return }
        let drafts = rows.map { row in
            row.committed ? SetDraft() : SetDraft(reps: row.reps, kg: row.kg)
        }
        session.saveDraft(drafts, for: exercise.id)
    }

    /// Valida uma linha e devolve a série; erros ficam visíveis na própria linha.
    private func validated(index: Int) -> VitalsLogSet? {
        guard let row = rows[safe: index] else { return nil }
        switch (WorkoutInput.parseReps(row.reps), WorkoutInput.parseWeight(row.kg)) {
        case (.success(let reps), .success(let kg)):
            rowError[index] = nil
            return VitalsLogSet(reps: reps, kg: kg)
        case (.failure(let error), _):
            rowError[index] = "reps: \(error.message)"
            return nil
        case (_, .failure(let error)):
            rowError[index] = "kg: \(error.message)"
            return nil
        }
    }

    // MARK: - Ações

    /// Conclui a série atual: persiste primeiro, só então marca e inicia o descanso.
    private func complete(index: Int) {
        guard !isBusy, currentIndex == index else { return }
        focused = nil
        failure = nil
        retry = nil
        let set = validated(index: index)
        let history = committedSets()
        guard let set, let history else {
            Haptics.failure()
            return
        }
        var payload = history
        payload.append(set)

        busyIndex = index
        Task {
            do {
                try await onSave(payload)
                rows[index].committed = true
                rows[index].original = set
                rowError[index] = nil
                persistDraft()
                Haptics.setLogged()
                if index + 1 < rows.count {
                    session.startRest(exerciseId: exercise.id, setIndex: index, restSec: exercise.restSec)
                }
            } catch {
                failure = error.localizedDescription
                retry = .complete(index)
                Haptics.failure()
            }
            busyIndex = nil
        }
    }

    private func undoLast() {
        guard !isBusy,
              let index = rows.lastIndex(where: \.committed),
              index == committedCount - 1 else { return }
        failure = nil
        retry = nil
        guard let history = committedSets() else {
            Haptics.failure()
            return
        }
        let payload = Array(history.dropLast())
        busyIndex = index
        Task {
            do {
                try await onSave(payload)
                rows[index].committed = false
                rows[index].original = nil
                session.skipRest()
                persistDraft()
            } catch {
                failure = error.localizedDescription
                retry = .undoLast
            }
            busyIndex = nil
        }
    }

    private func performRetry() {
        switch retry {
        case .complete(let index): complete(index: index)
        case .undoLast: undoLast()
        case nil: break
        }
    }

    /// Valida todo o histórico antes de construir um payload. Uma única linha
    /// inválida impede o POST, em vez de salvar silenciosamente só um prefixo.
    private func committedSets() -> [VitalsLogSet]? {
        var sets: [VitalsLogSet] = []
        var isValid = true
        for index in rows.indices where rows[index].committed {
            if let original = rows[index].original {
                sets.append(original)
            } else if let set = validated(index: index) {
                sets.append(set)
            } else {
                isValid = false
            }
        }
        return isValid ? sets : nil
    }
}

struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.paperTile)
                Capsule()
                    .fill(Color.primary)
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}
