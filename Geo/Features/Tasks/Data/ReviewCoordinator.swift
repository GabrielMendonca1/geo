import Foundation
import Combine
import SwiftUI

@MainActor
final class ReviewCoordinator: ObservableObject {
    enum PresentedReview: Identifiable, Equatable {
        case weekly
        case daily
        var id: String {
            switch self {
            case .weekly: return "weekly"
            case .daily: return "daily"
            }
        }
    }

    @Published var presented: PresentedReview?

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        return cal
    }()

    private let defaults: UserDefaults
    private static let weeklyKey = "review.lastWeeklyReview"
    private static let dailyKey = "review.lastDailyReview"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func checkPending(now: Date = Date()) {
        if presented != nil { return }
        if shouldShowWeekly(now: now) {
            presented = .weekly
            return
        }
        if shouldShowDaily(now: now) {
            presented = .daily
        }
    }

    func pendingReview(now: Date = Date()) -> PresentedReview? {
        if shouldShowWeekly(now: now) { return .weekly }
        if shouldShowDaily(now: now) { return .daily }
        return nil
    }

    func markWeeklyReviewed(now: Date = Date()) {
        defaults.set(now, forKey: Self.weeklyKey)
        if presented == .weekly { presented = nil }
    }

    func markDailyReviewed(now: Date = Date()) {
        defaults.set(now, forKey: Self.dailyKey)
        if presented == .daily { presented = nil }
    }

    func dismiss() {
        presented = nil
    }

    func forceWeekly() {
        presented = .weekly
    }

    func forceDaily() {
        presented = .daily
    }

    // MARK: - Triggers

    private func shouldShowWeekly(now: Date) -> Bool {
        guard calendar.component(.weekday, from: now) == 1 else { return false }
        guard let last = defaults.object(forKey: Self.weeklyKey) as? Date else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    private func shouldShowDaily(now: Date) -> Bool {
        guard let last = defaults.object(forKey: Self.dailyKey) as? Date else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    // MARK: - Week math (Sunday-based)

    func currentWeekStart(reference: Date = Date()) -> Date {
        startOfWeek(containing: reference)
    }

    func previousWeekStart(reference: Date = Date()) -> Date {
        let thisWeek = startOfWeek(containing: reference)
        return calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
    }

    func isInCurrentWeek(_ date: Date, reference: Date = Date()) -> Bool {
        let start = startOfWeek(containing: reference)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return false }
        return date >= start && date < end
    }

    func isInPreviousWeek(_ date: Date, reference: Date = Date()) -> Bool {
        let thisWeek = startOfWeek(containing: reference)
        guard let lastWeek = calendar.date(byAdding: .day, value: -7, to: thisWeek) else { return false }
        return date >= lastWeek && date < thisWeek
    }

    private func startOfWeek(containing date: Date) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysFromSunday = weekday - 1
        return calendar.date(byAdding: .day, value: -daysFromSunday, to: startOfDay) ?? startOfDay
    }
}
