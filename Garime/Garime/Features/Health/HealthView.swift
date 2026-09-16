import SwiftUI

struct HealthView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var loggingDay = ""
    @StateObject private var viewModel = HealthViewModel()
    @State private var showOnboarding = false
    @State private var loggingExercise: VitalsExercise?
    @State private var note = ""
    @AppStorage(GarimeAgent.sessionKey) private var agentSession = ""
    @StateObject private var vision = TrainingVisionModel(target: GarimeAgent.target(""))
    @StateObject private var workout = WorkoutSessionModel()
    @State private var photoExercise: VitalsExercise?
    @State private var showCamera = false
    @State private var reading: TrainingVisionReading?
    @State private var showWorkout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    homeIdentity

                    if let error = viewModel.errorMessage {
                        errorState(error)
                    } else if viewModel.isLoading, !viewModel.hasLoaded {
                        ProgressView()
                            .tint(.slateText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else if let session = viewModel.todaySession {
                        heroCard(for: session)
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
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .dockScrollTracking()
            .background(Color.slateCanvas)
            .navigationBarHidden(true)
            .refreshable {
                await viewModel.reload()
            }
            .navigationDestination(isPresented: $showWorkout) {
                if let session = viewModel.todaySession {
                    WorkoutDetailView(
                        viewModel: viewModel,
                        workout: workout,
                        session: session,
                        note: $note,
                        onLog: { exercise in
                            reading = nil
                            presentLog(exercise)
                        },
                        onPhoto: { exercise in
                            photoExercise = exercise
                            reading = nil
                            vision.reset()
                            showCamera = true
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Treino indisponível",
                        systemImage: "figure.strengthtraining.traditional",
                        description: Text("Volte e atualize para carregar o treino do dia.")
                    )
                    .navigationTitle("Treino")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar(.visible, for: .navigationBar)
                }
            }
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
                lastWeight: viewModel.lastWeight(for: exercise.id),
                reading: reading,
                session: workout
            ) { sets in
                try await viewModel.saveExercise(
                    exerciseId: exercise.id,
                    sets: sets,
                    expectedDay: loggingDay
                )
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView { data, _ in
                showCamera = false
                analyzePhoto(data)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) { visionStatus }
        .tint(Color.slateText)
        .task {
            await viewModel.reload()
            workout.adopt(day: viewModel.todayKey)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await viewModel.refreshIfDayChanged()
                    workout.adopt(day: viewModel.todayKey)
                }
            }
        }
        .onChange(of: viewModel.todayKey) { _, day in
            workout.adopt(day: day)
        }
        .onChange(of: viewModel.needsOnboarding) { _, needs in
            if needs, !showOnboarding { showOnboarding = true }
        }
        .onChange(of: viewModel.todayNote) { _, value in
            if note != value { note = value }
        }
    }

    private func presentLog(_ exercise: VitalsExercise) {
        loggingDay = viewModel.todayKey
        workout.adopt(day: loggingDay)
        loggingExercise = exercise
    }

    /// Identificação discreta da aba: sem título gigante e sem barra fixa —
    /// o protagonista da Home é o modelo muscular.
    private var homeIdentity: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("treino")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Spacer(minLength: 8)
            if !viewModel.isPlanPrimary, !viewModel.sessions.isEmpty {
                Button { showOnboarding = true } label: {
                    Text("trocar")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TrainingPalette.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Trocar o treino de hoje")
            }
        }
    }

    @ViewBuilder
    private func heroCard(for session: VitalsSession) -> some View {
        let summary = WorkoutProgress.session(exercises: session.exercises, loggedSets: loggedSets)
        let current = WorkoutProgress.current(exercises: session.exercises, loggedSets: loggedSets)

        WorkoutHeroCard(
            sessionName: session.short.lowercased() == session.name.lowercased()
                ? session.name
                : "\(session.short) · \(session.name)",
            highlighted: viewModel.highlightedMuscles,
            isRest: session.rest,
            progress: summary,
            currentName: current?.name,
            restLabel: workout.isResting ? workout.restLabel : nil,
            action: { openWorkout() }
        )
    }

    private func openWorkout() {
        workout.adopt(day: viewModel.todayKey)
        showWorkout = true
    }

    // MARK: - Foco do treino

    private func loggedSets(_ exerciseId: String) -> Int {
        viewModel.todayEntry(for: exerciseId)?.sets.count ?? 0
    }

    @ViewBuilder
    private var visionStatus: some View {
        switch vision.phase {
        case .idle, .done:
            EmptyView()
        case .uploading, .waiting:
            visionBadge(vision.phase == .uploading ? "enviando foto…" : "o agente está olhando…", spinner: true)
        case .failed(let message):
            visionBadge(message, spinner: false)
        }
    }

    private func visionBadge(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().tint(.slateText).scaleEffect(0.7)
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateText)
            if !spinner {
                Button("ok") { vision.reset() }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(shape: Capsule())
        .padding(.bottom, 90)
    }

    private func analyzePhoto(_ data: Data) {
        guard let exercise = photoExercise else { return }
        Task {
            await vision.analyze(image: data, exercise: exercise.name)
            if case .done(let result) = vision.phase {
                reading = result
                presentLog(exercise)
                vision.reset()
            }
        }
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
