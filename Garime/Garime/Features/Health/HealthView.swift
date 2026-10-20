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
    @State private var previewing: TrainingWeekEntry?
    @State private var showSettings = false

    private var entries: [TrainingWeekEntry] {
        TrainingWeekList.entries(
            plan: viewModel.plan,
            sessions: viewModel.sessions,
            todayIndex: viewModel.todayIndex,
            logs: viewModel.logs,
            today: viewModel.todayKey
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = viewModel.errorMessage, viewModel.plan == nil {
                        errorState(error)
                    } else if viewModel.isLoading, !viewModel.hasLoaded {
                        ProgressView()
                            .tint(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else if entries.isEmpty, viewModel.hasLoaded, !viewModel.needsOnboarding {
                        emptyCard("Sem treino cadastrado")
                    } else {
                        weekCard
                            .padding(.top, 8)
                        workoutList
                            .padding(.top, 28)
                    }

                    if let error = viewModel.planErrorMessage, !viewModel.isPlanPrimary, viewModel.errorMessage == nil {
                        Text("Plano semanal indisponível · \(error)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 120)
            }
            .dockScrollTracking()
            .background(Color.paperCanvas)
            .safeAreaInset(edge: .top, spacing: 0) { header }
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
            .navigationDestination(item: $previewing) { entry in
                WorkoutPreviewView(entry: entry)
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        .tint(Color.primary)
        .task {
            await viewModel.reload()
            workout.adopt(day: viewModel.todayKey)
            #if DEBUG
            debugAutoOpen()
            #endif
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

    #if DEBUG
    /// Simulador sem toque: `-geoOpenWorkout` abre o treino de hoje; `-geoOpenExercise` abre o
    /// primeiro exercício; `-geoRest` inicia o descanso (para checar o anel).
    private func debugAutoOpen() {
        let args = CommandLine.arguments
        guard args.contains("-geoOpenWorkout") || args.contains("-geoOpenExercise") else { return }
        showWorkout = true
        guard args.contains("-geoOpenExercise"),
              let exercise = viewModel.todaySession?.exercises.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            presentLog(exercise)
            if args.contains("-geoRest") {
                workout.startRest(exerciseId: exercise.id, setIndex: 0, restSec: exercise.restSec)
            }
        }
    }
    #endif

    // MARK: - Header

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                Text("Treino")
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Color.paperCard, in: Capsule())

            Spacer()

            HStack(spacing: 0) {
                if !viewModel.isPlanPrimary, !viewModel.sessions.isEmpty {
                    Button { showOnboarding = true } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Trocar o treino de hoje")
                }
                Button {
                    Task { await viewModel.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Atualizar")
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Ajustes")
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 4)
            .background(Color.paperCard, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .background(Color.paperCanvas)
    }

    // MARK: - Semana

    private var weekCard: some View {
        let summary = TrainingWeekList.summary(entries)
        let fraction = summary.total > 0 ? Double(summary.done) / Double(summary.total) : 0
        return VStack(alignment: .leading, spacing: 0) {
            Text(viewModel.isPlanPrimary ? "Esta semana" : "Protocolo")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(summary.done)")
                    .font(.system(size: 40, weight: .bold))
                Text("de \(summary.total) treinos")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.top, 6)
            ProgressBar(fraction: fraction)
                .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
    }

    // MARK: - Lista

    private var workoutList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Treinos")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
            VStack(spacing: 10) {
                ForEach(entries) { entry in
                    Button {
                        open(entry)
                    } label: {
                        TrainingWeekRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("training-day-\(entry.id)")
                }
            }
        }
    }

    private func open(_ entry: TrainingWeekEntry) {
        if entry.status == .today {
            workout.adopt(day: viewModel.todayKey)
            showWorkout = true
        } else {
            previewing = entry
        }
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
            .padding(.top, 8)
    }

    // MARK: - Foto

    @ViewBuilder
    private var visionStatus: some View {
        switch vision.phase {
        case .idle, .done:
            EmptyView()
        case .uploading, .waiting:
            visionBadge(vision.phase == .uploading ? "Enviando foto…" : "O agente está olhando…", spinner: true)
        case .failed(let message):
            visionBadge(message, spinner: false)
        }
    }

    private func visionBadge(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 8) {
            if spinner {
                ProgressView().tint(.primary).scaleEffect(0.7)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
            if !spinner {
                Button("OK") { vision.reset() }
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.paperCard, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
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

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Tentar de novo") {
                Task { await viewModel.reload() }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// Linha de treino da semana. Hoje é o cartão preto; feito leva check;
/// os demais ficam brancos.
struct TrainingWeekRow: View {
    let entry: TrainingWeekEntry

    private var isToday: Bool { entry.status == .today }
    private var foreground: Color { isToday ? Color.paperInk : Color.primary }
    private var dim: Color { isToday ? Color.paperInk.opacity(0.65) : Color.secondary }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(entry.weekday.prefix(3))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(dim)
                if !entry.dayNumber.isEmpty {
                    Text(entry.dayNumber.split(separator: " ").first.map(String.init) ?? "")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(foreground)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                (isToday ? Color.paperInk.opacity(0.14) : Color.paperTile),
                in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.label)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(foreground)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(dim)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isToday ? Color.primary : Color.paperCard),
            in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.weekday), \(entry.label), \(statusLabel)")
    }

    private var subtitle: String {
        if entry.rest { return "Descanso" }
        if !entry.muscles.isEmpty { return MuscleNames.line(entry.muscles) }
        return "\(entry.exerciseCount) exercícios"
    }

    @ViewBuilder
    private var trailing: some View {
        if entry.rest, entry.status != .today {
            Image(systemName: "moon.zzz")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
        } else {
            statusIcon
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.primary)
        case .today:
            HStack(spacing: 6) {
                Text("Hoje")
                    .font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.paperInk)
        case .missed:
            Image(systemName: "circle.dashed")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
        case .upcoming:
            Image(systemName: "circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.25))
        }
    }

    private var statusLabel: String {
        switch entry.status {
        case .done: return "concluído"
        case .today: return "hoje"
        case .missed: return "não feito"
        case .upcoming: return "a fazer"
        }
    }
}

/// Visão só-leitura de um treino que não é o de hoje.
struct WorkoutPreviewView: View {
    let entry: TrainingWeekEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.dayNumber.isEmpty ? entry.weekday : "\(entry.weekday) · \(entry.dayNumber)")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    Text(entry.label)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.primary)
                        .padding(.top, 4)
                    if !entry.rest {
                        BodyMapView(highlighted: Set(entry.muscles))
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))

                if entry.rest {
                    Text("Dia de descanso")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Exercícios")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                        VStack(spacing: 0) {
                            ForEach(Array(entry.exercises.enumerated()), id: \.element.id) { index, exercise in
                                if index > 0 {
                                    Divider().padding(.leading, 74).padding(.trailing, 20)
                                }
                                ExerciseRowLabel(exercise: exercise, detail: VitalsFormat.prescription(exercise.sets, doseType: exercise.doseType))
                            }
                        }
                        .background(Color.paperCard, in: RoundedRectangle(cornerRadius: PaperRadius.card, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .dockScrollTracking()
        .background(Color.paperCanvas)
        .navigationTitle(entry.weekday)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(Color.paperCanvas, for: .navigationBar)
    }
}

/// Linha de exercício no estilo da lista de lançamentos: mapa muscular em tile,
/// nome, detalhe. Sem ação própria.
struct ExerciseRowLabel: View {
    let exercise: VitalsExercise
    let detail: String
    var trailing: String? = nil
    var trailingStrong = false

    var body: some View {
        HStack(spacing: 14) {
            MuscleTile(muscles: exercise.muscles)
            VStack(alignment: .leading, spacing: 3) {
                Text(exercise.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 17, weight: trailingStrong ? .semibold : .regular))
                    .foregroundStyle(trailingStrong ? Color.primary : Color.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tile 44×44 com o mapa corporal destacando os músculos do exercício.
struct MuscleTile: View {
    let muscles: [String]

    var body: some View {
        BodyMapView(highlighted: Set(muscles))
            .padding(5)
            .frame(width: 44, height: 44)
            .background(Color.paperTile, in: RoundedRectangle(cornerRadius: PaperRadius.tile, style: .continuous))
            .accessibilityHidden(true)
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
