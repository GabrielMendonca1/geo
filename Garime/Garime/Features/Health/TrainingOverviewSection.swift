import SwiftUI

struct TrainingOverviewSection: View {
    let plan: WeeklyPlan?
    let today: String
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("semana")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.slateTextDim)

            if let plan {
                week(plan)
            } else if isLoading {
                ProgressView()
                    .tint(.slateText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let errorMessage {
                Text("semana indisponível · \(errorMessage)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.slateTextDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous))
            }
        }
    }

    private func week(_ plan: WeeklyPlan) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(plan.days.enumerated()), id: \.offset) { index, day in
                dayRow(day, index: index)
            }
        }
        .padding(8)
        .glassSurface(shape: RoundedRectangle(cornerRadius: SlateRadius.card, style: .continuous))
    }

    private func dayRow(_ day: WeeklyPlanDay, index: Int) -> some View {
        let isToday = day.date == today
        return HStack(spacing: 10) {
            Text(dayLabel(index: index, date: day.date))
                .font(.system(size: 10, weight: isToday ? .bold : .regular, design: .monospaced))
                .foregroundStyle(isToday ? TrainingPalette.accent : Color.slateTextDim)
                .frame(width: 48, alignment: .leading)

            Text(day.label.lowercased())
                .font(.system(size: 12, weight: isToday ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(day.rest ? Color.slateTextDim : Color.slateText)

            Spacer(minLength: 8)

            if isToday {
                TrainingBadge(text: "hoje", tint: TrainingPalette.accent)
            } else if day.rest {
                Text("descanso")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
            } else {
                Text("\(day.items.count) exercícios")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.slateTextFaint)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                .fill(isToday ? TrainingPalette.accentSoft : Color.slateInk(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SlateRadius.cell, style: .continuous)
                .stroke(isToday ? TrainingPalette.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func dayLabel(index: Int, date: String) -> String {
        let weekdays = ["seg", "ter", "qua", "qui", "sex", "sáb", "dom"]
        let day = date.split(separator: "-").last.map(String.init) ?? date
        return "\(weekdays[index % weekdays.count]) \(day)"
    }
}
