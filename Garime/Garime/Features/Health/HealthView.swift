import SwiftUI

struct HealthView: View {
    @StateObject private var viewModel = HealthViewModel()
    @State private var showOnboarding = false
    @State private var loggingExercise: VitalsExercise?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = viewModel.errorMessage {
                        errorState(error)
                    } else if viewModel.isLoading, !viewModel.hasLoaded {
                        ProgressView()
                            .tint(.slateText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else if let session = viewModel.todaySession {
                        sessionBody(for: session)
                    } else if viewModel.hasLoaded, !viewModel.needsOnboarding {
                        Text("sem protocolo")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.slateTextDim)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    }

                    if let error = viewModel.planErrorMessage, !viewModel.isPlanPrimary, viewModel.errorMessage == nil {
                        planFallback(error)
                    }

                    if viewModel.errorMessage == nil || viewModel.plan != nil {
                        TrainingOverviewSection(
                            plan: viewModel.plan,
                            today: viewModel.todayKey,
                            isLoading: viewModel.isLoading && !viewModel.hasLoaded,
                            errorMessage: viewModel.planErrorMessage
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color.slateCanvas)
            .safeAreaInset(edge: .top) { header }
            .navigationBarHidden(true)
            .refreshable {
                await viewModel.reload()
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingSheet(
                    title: viewModel.vitalsProtocol?.name ?? "",
                    sessions: viewModel.sessions,
                    selected: viewModel.todayIndex
                ) { index in
                    await viewModel.anchor(to: index)
                }
            }
            .sheet(item: $loggingExercise) { exercise in
                ExerciseLogSheet(
                    exercise: exercise,
                    logged: viewModel.todayEntry(for: exercise.id),
                    lastWeight: viewModel.lastWeight(for: exercise.id)
                ) { sets in
                    try await viewModel.saveExercise(
                        exerciseId: exercise.id,
                        sets: sets
                    )
                }
            }
        }
        .tint(Color.slateText)
        .task {
            await viewModel.reload()
        }
        .onChange(of: viewModel.needsOnboarding) { _, needs in
            if needs, !showOnboarding { showOnboarding = true }
        }
        .onChange(of: viewModel.todayNote) { _, value in
            if note != value { note = value }
        }
    }

    private var header: some View {
        GlassChrome {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.todaySession?.short.lowercased() ?? "saúde")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.slateText)
                Spacer(minLength: 8)
                if !viewModel.isPlanPrimary, !viewModel.sessions.isEmpty {
                    Button { showOnboarding = true } label: {
                        Text("trocar")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassSurface(shape: Capsule(), interactive: true)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
        }
    }

    @ViewBuilder
    private func sessionBody(for session: VitalsSession) -> some View {
        Text(session.name.lowercased())
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)

        BodyMapView(highlighted: viewModel.highlightedMuscles)
            .frame(height: 300)
            .frame(maxWidth: .infinity)

        if session.rest {
            Text("Descanso ativo — cardio")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(session.exercises.enumerated()), id: \.element.id) { index, exercise in
                    if index > 0 {
                        Divider().overlay(Color.slateStroke.opacity(0.4))
                    }
                    exerciseEntry(exercise, session: session)
                }
            }
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))

            noteField
        }
    }

    @ViewBuilder
    private func exerciseEntry(_ exercise: VitalsExercise, session: VitalsSession) -> some View {
        if exercise.doseType == .reps {
            Button {
                loggingExercise = exercise
            } label: {
                exerciseRow(exercise, session: session)
            }
            .buttonStyle(.plain)
        } else {
            exerciseRow(exercise, session: session)
        }
    }

    private func exerciseRow(_ exercise: VitalsExercise, session: VitalsSession) -> some View {
        let entry = viewModel.todayEntry(for: exercise.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exercise.name.lowercased())
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.slateText)
                Spacer(minLength: 8)
                if entry != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.slateTextDim)
                } else if viewModel.shouldIncreaseLoad(exercise) {
                    Text("subir carga")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(BodyMapPalette.highlight)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(BodyMapPalette.highlight.opacity(0.16), in: Capsule())
                }
            }
            if let entry {
                Text(VitalsFormat.logged(entry.sets))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.slateText)
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
        .padding(16)
        .contentShape(Rectangle())
    }

    private var noteField: some View {
        TextField("", text: $note, prompt: Text("nota").foregroundStyle(.tertiary))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)
            .submitLabel(.done)
            .onSubmit {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed != viewModel.todayNote else { return }
                Task { try? await viewModel.saveNote(note: trimmed) }
            }
            .padding(14)
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }

    private func planFallback(_ message: String) -> some View {
        Text("plano semanal indisponível; usando protocolo legado · \(message)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.slateTextDim)
            Button("tentar de novo") {
                Task { await viewModel.reload() }
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.slateText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

enum VitalsFormat {
    private static let number: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func kg(_ value: Double) -> String {
        let text = number.string(from: NSNumber(value: value)) ?? String(value)
        return "\(text) kg"
    }

    static func logged(_ sets: [VitalsLogSet]) -> String {
        guard !sets.isEmpty else { return "" }
        let reps = sets.map { "\($0.reps)" }.joined(separator: "/")
        let weights = sets.map(\.kg)
        if let first = weights.first, weights.allSatisfy({ $0 == first }) {
            return "\(kg(first)) · \(reps)"
        }
        return sets.map { "\($0.reps)×\(kg($0.kg))" }.joined(separator: " / ")
    }

    static func prescription(_ sets: [[Int]], doseType: TrainingDoseType = .reps) -> String {
        guard !sets.isEmpty else { return "" }
        let ranges = sets.map { range -> String in
            guard let low = range.first, let high = range.last else { return "" }
            return low == high ? "\(low)" : "\(low)–\(high)"
        }
        let noun = sets.count == 1 ? "série" : "séries"
        if doseType != .reps {
            let unit = doseType == .timeMin ? "min" : "s"
            if sets.count == 1 {
                return "\(ranges[0]) \(unit)"
            }
            if let first = ranges.first, ranges.allSatisfy({ $0 == first }) {
                return "\(sets.count) \(noun) · \(first) \(unit)"
            }
            return "\(sets.count) \(noun) · \(ranges.joined(separator: " / ")) \(unit)"
        }
        if let first = ranges.first, ranges.allSatisfy({ $0 == first }) {
            return "\(sets.count) \(noun) · \(first)"
        }
        return "\(sets.count) \(noun) · \(ranges.joined(separator: " / "))"
    }
}

#Preview {
    HealthView()
}
