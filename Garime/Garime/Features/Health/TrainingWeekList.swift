import Foundation
import SwiftUI

/// Um treino na lista da Home: de qual dia é, o que é, e em que pé está.
struct TrainingWeekEntry: Identifiable, Hashable {
    enum Status: Equatable {
        case done
        case today
        case upcoming
        case missed
    }

    var id: String
    var dayKey: String
    var weekday: String
    var dayNumber: String
    var label: String
    var rest: Bool
    var exerciseCount: Int
    var status: Status
    var muscles: [String]
    var exercises: [VitalsExercise]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status && lhs.label == rhs.label
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum TrainingWeekList {
    /// Monta a lista da semana a partir do plano; sem plano, usa o protocolo
    /// legado girando a partir do treino de hoje.
    static func entries(
        plan: WeeklyPlan?,
        sessions: [VitalsSession],
        todayIndex: Int?,
        logs: [VitalsLog],
        today: String
    ) -> [TrainingWeekEntry] {
        if let plan {
            return plan.days.map { day in
                let logged = logs.first { $0.date == day.date }?.exercises.contains { !$0.sets.isEmpty } ?? false
                let status: TrainingWeekEntry.Status
                if day.date == today {
                    status = .today
                } else if logged {
                    status = .done
                } else if day.date < today {
                    status = day.rest ? .done : .missed
                } else {
                    status = .upcoming
                }
                let exercises = day.items.map(\.vitalsExercise)
                return TrainingWeekEntry(
                    id: day.date,
                    dayKey: day.date,
                    weekday: weekdayName(day.date),
                    dayNumber: dayNumber(day.date),
                    label: day.label,
                    rest: day.rest,
                    exerciseCount: day.items.count,
                    status: status,
                    muscles: Array(Set(day.items.flatMap(\.muscles))).sorted(),
                    exercises: exercises
                )
            }
        }

        guard !sessions.isEmpty else { return [] }
        let recent = Set(logs.prefix(14).compactMap(\.sessionIndex))
        return sessions.map { session in
            let isToday = session.index == todayIndex
            let status: TrainingWeekEntry.Status = isToday ? .today : (recent.contains(session.index) ? .done : .upcoming)
            return TrainingWeekEntry(
                id: "legacy-\(session.index)",
                dayKey: "",
                weekday: session.short,
                dayNumber: "",
                label: session.name,
                rest: session.rest,
                exerciseCount: session.exercises.count,
                status: status,
                muscles: session.muscles,
                exercises: session.exercises
            )
        }
    }

    static func weekdayName(_ dayKey: String) -> String {
        guard let date = parse(dayKey) else { return dayKey }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE"
        let raw = formatter.string(from: date)
        let short = raw.components(separatedBy: "-").first ?? raw
        return short.prefix(1).uppercased() + short.dropFirst()
    }

    static func dayNumber(_ dayKey: String) -> String {
        guard let date = parse(dayKey) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    private static func parse(_ dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func summary(_ entries: [TrainingWeekEntry]) -> (done: Int, total: Int) {
        let workouts = entries.filter { !$0.rest }
        return (workouts.filter { $0.status == .done }.count, workouts.count)
    }
}

/// Nome legível para o slug de músculo do mapa corporal.
enum MuscleNames {
    static func label(_ slug: String) -> String {
        switch slug {
        case "chest": return "Peito"
        case "abs": return "Abdômen"
        case "obliques": return "Oblíquos"
        case "biceps": return "Bíceps"
        case "triceps": return "Tríceps"
        case "forearms", "forearm": return "Antebraço"
        case "deltoids", "shoulders": return "Ombros"
        case "trapezius", "traps": return "Trapézio"
        case "neck": return "Pescoço"
        case "upper-back", "upper_back", "lats": return "Costas"
        case "lower-back", "lower_back": return "Lombar"
        case "glutes", "gluteal": return "Glúteos"
        case "quadriceps", "quads": return "Quadríceps"
        case "hamstrings", "hamstring": return "Posterior"
        case "calves": return "Panturrilha"
        case "adductors": return "Adutores"
        case "abductors": return "Abdutores"
        default:
            let cleaned = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
    }

    static func line(_ slugs: [String]) -> String {
        Array(Set(slugs)).sorted().map(label).joined(separator: " · ")
    }
}
