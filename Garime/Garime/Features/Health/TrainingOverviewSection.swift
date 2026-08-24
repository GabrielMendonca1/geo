import Combine
import Foundation
import SwiftUI

@MainActor
final class WeekPlanViewModel: ObservableObject {
    @Published private(set) var catalog: TrainingCatalog?
    @Published private(set) var blocks: TrainingBlocks?
    @Published private(set) var plan: WeeklyPlan?
    @Published private(set) var requestedWeek = ""
    @Published private(set) var today = ""
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var planErrorMessage: String?
    @Published private(set) var catalogErrorMessage: String?
    @Published private(set) var blocksErrorMessage: String?

    private let repository: BridgeTrainingRepository

    init(repository: BridgeTrainingRepository = BridgeTrainingRepository()) {
        self.repository = repository
    }

    var hasContent: Bool {
        plan != nil || catalog != nil || blocks != nil
    }

    func reload(date: Date = Date()) async {
        requestedWeek = BridgeTrainingRepository.isoWeek(for: date)
        today = BridgeVitalsRepository.dayFormatter.string(from: date)
        if plan?.week != requestedWeek {
            plan = nil
        }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        async let planRequest = repository.fetchPlan(week: requestedWeek)
        async let catalogRequest = repository.fetchCatalog()
        async let blocksRequest = repository.fetchBlocks()

        do {
            plan = try await planRequest
            planErrorMessage = nil
        } catch {
            planErrorMessage = error.localizedDescription
        }

        do {
            catalog = try await catalogRequest
            catalogErrorMessage = nil
        } catch {
            catalog = nil
            catalogErrorMessage = error.localizedDescription
        }

        do {
            blocks = try await blocksRequest
            blocksErrorMessage = nil
        } catch {
            blocks = nil
            blocksErrorMessage = error.localizedDescription
        }
    }
}

struct TrainingOverviewSection: View {
    @ObservedObject var viewModel: WeekPlanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("semana")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)

            if let plan = viewModel.plan {
                week(plan)
                if let error = viewModel.planErrorMessage {
                    resourceError("atualização da semana", error)
                }
            } else if viewModel.isLoading, !viewModel.hasLoaded {
                ProgressView()
                    .tint(.slateText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if let error = viewModel.planErrorMessage {
                errorState(error)
            } else if viewModel.hasLoaded {
                Text("Nenhum plano congelado para esta semana")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
            }

            library
        }
    }

    private func week(_ plan: WeeklyPlan) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.days.enumerated()), id: \.offset) { index, day in
                if index > 0 {
                    Divider().overlay(Color.slateStroke.opacity(0.4))
                }
                dayRow(day)
            }
            Divider().overlay(Color.slateStroke.opacity(0.4))
            Text("\(plan.week) · revisão \(plan.revision) · congelado \(plan.frozenAt)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func dayRow(_ day: WeeklyPlanDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.date)
                    .font(.system(size: 11, weight: day.date == viewModel.today ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(day.date == viewModel.today ? Color.slateText : Color.slateTextDim)
                Text(day.label.lowercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.slateText)
                Spacer(minLength: 8)
                if day.rest {
                    Text("descanso")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.slateTextFaint)
                }
            }
            ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name.lowercased())
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.slateTextDim)
                    Spacer(minLength: 8)
                    Text("\(VitalsFormat.sets(item.sets)) · \(item.restSec)s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.slateTextFaint)
                }
            }
        }
        .padding(12)
        .background(day.date == viewModel.today ? Color.slateText.opacity(0.06) : Color.clear)
    }

    @ViewBuilder
    private var library: some View {
        Text("catálogo e blocos")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)
            .padding(.top, 4)

        if let catalog = viewModel.catalog {
            VStack(spacing: 0) {
                ForEach(Array(catalog.exercises.enumerated()), id: \.offset) { index, exercise in
                    if index > 0 {
                        Divider().overlay(Color.slateStroke.opacity(0.4))
                    }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name.lowercased())
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.slateText)
                            Text(exercise.id)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.slateTextFaint)
                        }
                        Spacer(minLength: 8)
                        Text(exercise.status.rawValue)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.slateTextDim)
                    }
                    .padding(12)
                }
            }
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
        } else if let error = viewModel.catalogErrorMessage {
            resourceError("catálogo", error)
        } else if viewModel.hasLoaded {
            Text("Catálogo ainda não publicado")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
        }

        if let blocks = viewModel.blocks {
            ForEach(Array(blocks.blocks.enumerated()), id: \.offset) { _, block in
                HStack {
                    Text(block.name.lowercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.slateText)
                    Spacer(minLength: 8)
                    Text("v\(block.version) · \(block.items.count) exercícios")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.slateTextFaint)
                }
                .padding(12)
                .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
            }
        } else if let error = viewModel.blocksErrorMessage {
            resourceError("blocos", error)
        } else if viewModel.hasLoaded {
            Text("Blocos ainda não publicados")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextFaint)
        }
    }

    private func resourceError(_ resource: String, _ message: String) -> some View {
        Text("\(resource): \(message)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Color.slateTextDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)
            Button("tentar de novo") {
                Task { await viewModel.reload() }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.slateText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }
}
