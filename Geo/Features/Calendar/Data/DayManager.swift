import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "DayManager")

class DayManager: ObservableObject {
    @Published private(set) var currentDayId: String?
    private var midnightCheckTimer: AnyCancellable?
    private let dayRepository: any DayRepository
    private let captureRepository: any CaptureRepository

    init(
        dayRepository: any DayRepository,
        captureRepository: any CaptureRepository
    ) {
        self.dayRepository = dayRepository
        self.captureRepository = captureRepository
        start()
        startMidnightMonitor()
    }

    func start() {
        updateCurrentDayId()
    }

    func recordCaptureCreation(id: UUID, date: Date = Date(), dayId: String? = nil) {
        Task {
            let targetDate = dayId.flatMap(Self.date(from:)) ?? date
            let normalizedDate = Calendar.current.startOfDay(for: targetDate)
            let resolvedDayId = Day.idFromDate(normalizedDate)
            // Capture-day membership is owned by CaptureItem.dayId (the capture repository),
            // not days.json — DayStore no longer persists capture links.
            do {
                try await captureRepository.linkToDay(captureId: id, dayId: resolvedDayId)
            } catch {
                logger.error("Failed to link capture \(id) to day \(resolvedDayId): \(error.localizedDescription)")
            }
        }
    }

    private func updateCurrentDayId() {
        currentDayId = Day.idFromDate(Date())
    }

    private func startMidnightMonitor() {
        scheduleMidnightCheck()
    }

    private func scheduleMidnightCheck() {
        midnightCheckTimer?.cancel()
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) else { return }
        let delay = max(1, tomorrow.timeIntervalSinceNow + 1)
        midnightCheckTimer = Timer.publish(every: delay, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in
                self?.checkForDayChange()
                self?.scheduleMidnightCheck()
            }
    }

    private func checkForDayChange() {
        let newDayId = Day.idFromDate(Date())
        if newDayId != currentDayId {
            transitionToNewDay()
        }
    }

    private func transitionToNewDay() {
        updateCurrentDayId()
    }

    private static func date(from dayId: String) -> Date? {
        DateFormatters.dayId.date(from: dayId)
    }
}
