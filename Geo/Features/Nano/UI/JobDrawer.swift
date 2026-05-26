import SwiftUI

enum JobDrawerMode: Equatable {
    case add
    case view(id: String)
}

struct JobDrawer: View {
    let mode: JobDrawerMode
    @ObservedObject var store: JobStore
    var runtimeLookup: ((String) -> JobRuntime?)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var prompt: String = ""
    @State private var cadenceKind: CadenceKind = .daily
    @State private var dailyTime: Date = JobDrawer.defaultDailyTime()
    @State private var weeklyDay: Int = 1
    @State private var weeklyTime: Date = JobDrawer.defaultDailyTime()
    @State private var everyN: Int = 15
    @State private var sinkTelegram: Bool = true
    @State private var sinkWhatsapp: Bool = false
    @State private var sinkNotification: Bool = true
    @State private var confirmDelete: Bool = false
    @State private var saveError: String?

    enum CadenceKind: String, CaseIterable, Identifiable {
        case hourly
        case daily
        case weekly
        case everyMinutes

        var id: String { rawValue }
        var label: String {
            switch self {
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .everyMinutes: return "Every N min"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch mode {
            case .add: addBody
            case .view(let id): viewBody(id: id)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text(mode == .add ? "New Job" : "Job")
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    @ViewBuilder
    private var addBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fieldGroup(label: "Title") {
                    TextField("e.g. Morning digest", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                fieldGroup(label: "Prompt") {
                    TextEditor(text: $prompt)
                        .font(.body)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                }
                fieldGroup(label: "Cadence") {
                    Picker("", selection: $cadenceKind) {
                        ForEach(CadenceKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    cadenceDetail
                }
                fieldGroup(label: "Sinks") {
                    HStack(spacing: 14) {
                        Toggle("Telegram", isOn: $sinkTelegram)
                        Toggle("WhatsApp", isOn: $sinkWhatsapp)
                        Toggle("Notification", isOn: $sinkNotification)
                    }
                    .toggleStyle(.checkbox)
                    if !hasAnySink {
                        Text("Pick at least one sink.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var cadenceDetail: some View {
        switch cadenceKind {
        case .hourly:
            Text("Runs at the top of every hour.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .daily:
            DatePicker("Time", selection: $dailyTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
        case .weekly:
            HStack(spacing: 12) {
                Picker("Day", selection: $weeklyDay) {
                    ForEach(1...7, id: \.self) { day in
                        Text(weekdayLabel(day)).tag(day)
                    }
                }
                .frame(maxWidth: 160)
                DatePicker("Time", selection: $weeklyTime, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
            }
        case .everyMinutes:
            Stepper("Every \(everyN) minutes", value: $everyN, in: 5...60, step: 5)
        }
    }

    @ViewBuilder
    private func viewBody(id: String) -> some View {
        if let job = store.jobs.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 14) {
                fieldGroup(label: "Title") {
                    Text(job.spec.title).font(.body)
                }
                fieldGroup(label: "Cadence") {
                    Text(JobDrawer.cronToHumanReadable(job.spec.cron))
                        .font(.body)
                    Text(job.spec.cron)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                fieldGroup(label: "Prompt") {
                    ScrollView {
                        Text(job.spec.prompt)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                fieldGroup(label: "Sinks") {
                    Text(job.spec.sinks.joined(separator: ", "))
                        .font(.body)
                }
                fieldGroup(label: "Last run") {
                    let runtime = runtimeLookup?(job.id) ?? job.runtime
                    runtimeBadge(runtime)
                    if let err = runtime?.error, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .confirmationDialog(
                "Delete \(job.spec.title)?",
                isPresented: $confirmDelete
            ) {
                Button("Delete", role: .destructive) {
                    try? store.remove(job.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This stops the cron and removes the spec.")
            }
        } else {
            Text("Job not found.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
    }

    private func runtimeBadge(_ runtime: JobRuntime?) -> some View {
        let status = runtime?.lastStatus ?? "never"
        let color: Color
        switch status {
        case "ok": color = Color(red: 0.18, green: 0.78, blue: 0.46)
        case "error": color = Color(red: 0.95, green: 0.32, blue: 0.32)
        default: color = Color(white: 0.55)
        }
        let label: String = {
            if let last = runtime?.lastRun {
                let f = DateFormatter()
                f.dateStyle = .short
                f.timeStyle = .short
                return "\(status) · \(f.string(from: last))"
            }
            return "never run"
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func fieldGroup<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var hasAnySink: Bool {
        sinkTelegram || sinkWhatsapp || sinkNotification
    }

    private var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasAnySink
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let cron = currentCron()
        var sinks: [String] = []
        if sinkTelegram { sinks.append("telegram") }
        if sinkWhatsapp { sinks.append("whatsapp") }
        if sinkNotification { sinks.append("notification") }
        let spec = JobSpec(
            id: JobSlug.jobID(from: cleanTitle),
            title: cleanTitle,
            cron: cron,
            prompt: cleanPrompt,
            sinks: sinks
        )
        do {
            try store.add(spec)
            saveError = nil
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func currentCron() -> String {
        switch cadenceKind {
        case .hourly:
            return "0 * * * *"
        case .daily:
            let comps = Calendar.current.dateComponents([.hour, .minute], from: dailyTime)
            return "\(comps.minute ?? 0) \(comps.hour ?? 0) * * *"
        case .weekly:
            let comps = Calendar.current.dateComponents([.hour, .minute], from: weeklyTime)
            return "\(comps.minute ?? 0) \(comps.hour ?? 0) * * \(weeklyDay)"
        case .everyMinutes:
            return "*/\(everyN) * * * *"
        }
    }

    private func weekdayLabel(_ day: Int) -> String {
        switch day {
        case 0, 7: return "Sun"
        case 1: return "Mon"
        case 2: return "Tue"
        case 3: return "Wed"
        case 4: return "Thu"
        case 5: return "Fri"
        case 6: return "Sat"
        default: return "Day \(day)"
        }
    }

    private static func defaultDailyTime() -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 7
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    static func cronToHumanReadable(_ cron: String) -> String {
        let parts = cron.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return cron }
        let minute = parts[0]
        let hour = parts[1]
        let dom = parts[2]
        let month = parts[3]
        let dow = parts[4]
        if minute == "0" && hour == "*" && dom == "*" && month == "*" && dow == "*" {
            return "Every hour"
        }
        if minute.hasPrefix("*/") && hour == "*" && dom == "*" && month == "*" && dow == "*" {
            let n = String(minute.dropFirst(2))
            return "Every \(n) minutes"
        }
        if let m = Int(minute), let h = Int(hour), dom == "*" && month == "*" && dow == "*" {
            return "Daily at \(String(format: "%02d:%02d", h, m))"
        }
        if let m = Int(minute), let h = Int(hour), let wd = Int(dow), dom == "*" && month == "*" {
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            let label = (wd >= 0 && wd < names.count) ? names[wd] : "Day \(wd)"
            return "Weekly · \(label) at \(String(format: "%02d:%02d", h, m))"
        }
        return cron
    }
}
