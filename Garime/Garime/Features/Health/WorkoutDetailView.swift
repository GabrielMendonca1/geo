import SwiftUI

/// Tela dedicada do treino do dia. Empurrada pela Home no mesmo `NavigationStack`
/// e com os **mesmos** modelos (`HealthViewModel` / `WorkoutSessionModel`):
/// nada é refeito aqui — sem novo fetch, sem novo timer, sem novo rascunho.
struct WorkoutDetailView: View {
    @ObservedObject var viewModel: HealthViewModel
    @ObservedObject var workout: WorkoutSessionModel
    let session: VitalsSession
    @Binding var note: String
    let onLog: (VitalsExercise) -> Void
    let onPhoto: (VitalsExercise) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(session.name.lowercased())
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)

                if session.rest {
                    restDayCard
                } else {
                    focusCard
                    exerciseList
                    BodyMapView(highlighted: viewModel.highlightedMuscles)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .opacity(0.9)
                        .accessibilityHidden(true)
                }
                noteField
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .padding(.top, 4)
        }
        .dockScrollTracking()
        .background(Color.slateCanvas)
        .navigationTitle(session.short.lowercased())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    // MARK: - Progresso

    private func loggedSets(_ exerciseId: String) -> Int {
        viewModel.todayEntry(for: exerciseId)?.sets.count ?? 0
    }

    private func setProgress(for exercise: VitalsExercise) -> ExerciseProgress {
        WorkoutProgress.exercise(prescribed: exercise.sets, loggedSets: loggedSets(exercise.id))
    }

    private var restDayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("descanso ativo · cardio")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateText)
            Text("sem séries de força hoje. Use a nota do dia se quiser registrar algo.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    @ViewBuilder
    private var focusCard: some View {
        let summary = WorkoutProgress.session(exercises: session.exercises, loggedSets: loggedSets)
        let current = WorkoutProgress.current(exercises: session.exercises, loggedSets: loggedSets)
        let next = WorkoutProgress.next(exercises: session.exercises, after: current?.id, loggedSets: loggedSets)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                if summary.isComplete {
                    TrainingBadge(text: "séries concluídas", tint: TrainingPalette.done, systemImage: "checkmark")
                } else {
                    TrainingBadge(text: "agora", tint: TrainingPalette.accent, systemImage: "bolt.fill")
                }
                Spacer(minLength: 8)
                Text("\(summary.setsDone)/\(summary.setsTarget) séries · \(summary.exercisesDone)/\(summary.exercisesTarget) exercícios")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
            }

            ProgressBar(fraction: summary.fraction)

            if workout.rest != nil {
                restStrip
            }

            if let current {
                Button {
                    onLog(current)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(current.name.lowercased())
                                .font(.system(size: 19, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.slateText)
                                .multilineTextAlignment(.leading)
                            Text(currentSubtitle(current))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.slateTextDim)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TrainingPalette.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                            .fill(TrainingPalette.accentSoft)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                            .stroke(TrainingPalette.accent.opacity(0.5), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Registrar \(current.name)")
            } else {
                Text(summary.exercisesTarget == 0
                     ? "consulte abaixo as atividades por tempo."
                     : "séries de força registradas. Confira abaixo as atividades por tempo, se houver.")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.slateText)
            }

            if let next {
                Text("próximo · \(next.name.lowercased()) · \(VitalsFormat.prescription(next.sets, doseType: next.doseType))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func currentSubtitle(_ exercise: VitalsExercise) -> String {
        let progress = setProgress(for: exercise)
        var parts = ["série \(min(progress.done + 1, max(progress.target, 1))) de \(progress.target)"]
        if let reps = WorkoutProgress.suggestedReps(prescribed: exercise.sets, index: progress.done) {
            parts.append("alvo \(reps) reps")
        }
        if let weight = viewModel.lastWeight(for: exercise.id) {
            parts.append("última \(VitalsFormat.kg(weight))")
        }
        return parts.joined(separator: " · ")
    }

    private var restStrip: some View {
        HStack(spacing: 12) {
            Text(workout.restLabel)
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(workout.remaining > 0 ? TrainingPalette.accent : TrainingPalette.done)
            Text(workout.remaining > 0 ? "descanso" : "pode ir")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Spacer(minLength: 8)
            Button("reiniciar") { workout.restartRest() }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
                .frame(minHeight: 44)
            Button("pular") { workout.skipRest() }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(TrainingPalette.accent)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }

    // MARK: - Lista de exercícios

    private var exerciseList: some View {
        VStack(spacing: 6) {
            ForEach(session.exercises) { exercise in
                exerciseEntry(exercise)
            }
        }
        .padding(8)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    @ViewBuilder
    private func exerciseEntry(_ exercise: VitalsExercise) -> some View {
        if exercise.doseType == .reps {
            HStack(spacing: 0) {
                Button {
                    onLog(exercise)
                } label: {
                    exerciseRow(exercise)
                }
                .buttonStyle(.plain)

                Button {
                    onPhoto(exercise)
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TrainingPalette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ler máquina e peso pela foto")
                .padding(.trailing, 4)
            }
            .background(rowBackground(exercise))
        } else {
            Button {
                onLog(exercise)
            } label: {
                exerciseRow(exercise)
            }
            .buttonStyle(.plain)
            .background(rowBackground(exercise))
        }
    }

    /// Fundo sempre arredondado — o estado "agora" nunca vaza um retângulo
    /// sobre os cantos do cartão.
    private func rowBackground(_ exercise: VitalsExercise) -> some View {
        let progress = setProgress(for: exercise)
        let isCurrent = WorkoutProgress.current(exercises: session.exercises, loggedSets: loggedSets)?.id == exercise.id
        let state: TrainingRowState = isCurrent ? .current : (progress.isComplete ? .done : .idle)
        return TrainingRowBackground(state: state)
    }

    private func exerciseRow(_ exercise: VitalsExercise) -> some View {
        let entry = viewModel.todayEntry(for: exercise.id)
        let progress = setProgress(for: exercise)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exercise.name.lowercased())
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.slateText)
                Spacer(minLength: 8)
                if WorkoutProgress.isTrackable(exercise), progress.isStarted {
                    Text("\(progress.done)/\(progress.target)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(progress.isComplete ? TrainingPalette.done : Color.slateTextDim)
                }
                if progress.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TrainingPalette.done)
                        .accessibilityLabel("concluído")
                } else if !progress.isStarted, viewModel.shouldIncreaseLoad(exercise) {
                    TrainingBadge(text: "subir carga", tint: TrainingPalette.attention, systemImage: "arrow.up")
                }
            }
            if let entry, !entry.sets.isEmpty {
                HStack(spacing: 8) {
                    Text(VitalsFormat.logged(entry.sets))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.slateText)
                    if progress.isPartial {
                        Text("faltam \(progress.target - progress.done)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TrainingPalette.attention)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text(VitalsFormat.prescription(exercise.sets, doseType: exercise.doseType))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                    if let restSec = exercise.restSec, restSec > 0 {
                        Text("\(restSec)s")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.slateTextFaint)
                    }
                    if let weight = viewModel.lastWeight(for: exercise.id) {
                        Text(VitalsFormat.kg(weight))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.slateTextFaint)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(minHeight: 44)
        .contentShape(RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }

    private var noteField: some View {
        TextField("", text: $note, prompt: Text("nota").foregroundStyle(Color.slateTextDim))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)
            .submitLabel(.done)
            .accessibilityLabel("Nota do dia")
            .onSubmit {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed != viewModel.todayNote else { return }
                Task { try? await viewModel.saveNote(note: trimmed) }
            }
            .padding(14)
            .frame(minHeight: 44)
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }
}
