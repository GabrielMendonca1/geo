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
            VStack(alignment: .leading, spacing: 28) {
                if session.rest {
                    restDayCard
                } else {
                    focusCard
                    exerciseList
                }
                noteField
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
            .padding(.top, 8)
        }
        .dockScrollTracking()
        .background(Color.paperCanvas)
        .navigationTitle(session.short)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.paperCanvas, for: .navigationBar)
    }

    // MARK: - Progresso

    private func loggedSets(_ exerciseId: String) -> Int {
        viewModel.todayEntry(for: exerciseId)?.sets.count ?? 0
    }

    private func setProgress(for exercise: VitalsExercise) -> ExerciseProgress {
        WorkoutProgress.exercise(prescribed: exercise.sets, loggedSets: loggedSets(exercise.id))
    }

    private var currentExercise: VitalsExercise? {
        WorkoutProgress.current(exercises: session.exercises, loggedSets: loggedSets)
    }

    private var restDayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Descanso ativo")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            Text("Sem séries de força hoje")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.primary)
            Text("Cardio leve ou caminhada. Use a nota do dia se quiser registrar algo.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    @ViewBuilder
    private var focusCard: some View {
        let summary = WorkoutProgress.session(exercises: session.exercises, loggedSets: loggedSets)
        let current = currentExercise
        let next = WorkoutProgress.next(exercises: session.exercises, after: current?.id, loggedSets: loggedSets)

        VStack(alignment: .leading, spacing: 0) {
            Text(summary.isComplete ? "Treino concluído" : "Progresso")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(summary.setsDone)")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.primary)
                Text("de \(summary.setsTarget) séries")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            ProgressBar(fraction: summary.fraction)
                .padding(.top, 20)

            if workout.rest != nil {
                restStrip
                    .padding(.top, 20)
            }

            if let current {
                Button {
                    onLog(current)
                } label: {
                    HStack(spacing: 14) {
                        MuscleTile(muscles: current.muscles)
                            .colorScheme(.dark)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.name)
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                            Text(currentSubtitle(current))
                                .font(.system(size: 15))
                                .opacity(0.7)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color.paperInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 20)
                .accessibilityLabel("Registrar \(current.name)")
            }

            if let next {
                Text("Próximo · \(next.name)")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    private func currentSubtitle(_ exercise: VitalsExercise) -> String {
        let progress = setProgress(for: exercise)
        var parts = ["Série \(min(progress.done + 1, max(progress.target, 1))) de \(progress.target)"]
        if let reps = WorkoutProgress.suggestedReps(prescribed: exercise.sets, index: progress.done) {
            parts.append("\(reps) reps")
        }
        if let weight = viewModel.lastWeight(for: exercise.id) {
            parts.append(VitalsFormat.kg(weight))
        }
        return parts.joined(separator: " · ")
    }

    private var restStrip: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.remaining > 0 ? "Descanso" : "Pode ir")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(workout.restLabel)
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
            }
            Spacer(minLength: 8)
            Button("Reiniciar") { workout.restartRest() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
            Button("Pular") { workout.skipRest() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.paperTile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Lista de exercícios

    private var exerciseList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exercícios")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            VStack(spacing: 0) {
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, exercise in
                    if index > 0 {
                        Divider().padding(.leading, 74).padding(.trailing, 20)
                    }
                    exerciseEntry(exercise)
                }
            }
            .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
        }
    }

    @ViewBuilder
    private func exerciseEntry(_ exercise: VitalsExercise) -> some View {
        HStack(spacing: 0) {
            Button {
                onLog(exercise)
            } label: {
                exerciseRow(exercise)
            }
            .buttonStyle(.plain)

            if exercise.doseType == .reps {
                Button {
                    onPhoto(exercise)
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ler máquina e peso pela foto")
                .padding(.trailing, 10)
            }
        }
    }

    private func exerciseRow(_ exercise: VitalsExercise) -> some View {
        let entry = viewModel.todayEntry(for: exercise.id)
        let progress = setProgress(for: exercise)
        let isCurrent = currentExercise?.id == exercise.id

        var detail: String
        if let entry, !entry.sets.isEmpty {
            detail = VitalsFormat.logged(entry.sets)
        } else {
            detail = VitalsFormat.prescription(exercise.sets, doseType: exercise.doseType)
            if let weight = viewModel.lastWeight(for: exercise.id) {
                detail += " · \(VitalsFormat.kg(weight))"
            }
        }

        return HStack(spacing: 14) {
            MuscleTile(muscles: exercise.muscles)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(exercise.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    if !progress.isStarted, viewModel.shouldIncreaseLoad(exercise) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("subir carga")
                    }
                }
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing(progress: progress, isCurrent: isCurrent, trackable: WorkoutProgress.isTrackable(exercise))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func trailing(progress: ExerciseProgress, isCurrent: Bool, trackable: Bool) -> some View {
        if progress.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.primary)
                .accessibilityLabel("concluído")
        } else if trackable, progress.isStarted {
            Text("\(progress.done)/\(progress.target)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
        } else if isCurrent {
            Circle()
                .fill(Color.primary)
                .frame(width: 10, height: 10)
                .accessibilityLabel("atual")
        } else {
            Image(systemName: "circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.25))
        }
    }

    private var noteField: some View {
        TextField("", text: $note, prompt: Text("Nota do dia").foregroundStyle(.secondary))
            .font(.system(size: 17))
            .foregroundStyle(Color.primary)
            .submitLabel(.done)
            .accessibilityLabel("Nota do dia")
            .onSubmit {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed != viewModel.todayNote else { return }
                Task { try? await viewModel.saveNote(note: trimmed) }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }
}
