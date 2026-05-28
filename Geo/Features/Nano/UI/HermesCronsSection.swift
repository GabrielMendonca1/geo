import SwiftUI

struct HermesCronsSection: View {
    @StateObject private var store = JobStore()
    @State private var showAdd: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Crons")
                    .font(GeoStyle.Typography.titleFont(size: 17))
                    .foregroundStyle(Palette.foreground)
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                        Text("Add").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(Palette.foreground)
                    .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            if store.jobs.isEmpty {
                Text("No scheduled prompts. Add one to have hermes run a prompt on a cron schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.jobs) { job in
                        CronRow(job: job, onRemove: {
                            try? store.remove(job.id)
                        })
                    }
                }
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .task { store.refresh() }
        .sheet(isPresented: $showAdd) {
            CronAddSheet(store: store, isPresented: $showAdd)
        }
    }
}

private struct CronRow: View {
    let job: Job
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.spec.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(job.spec.cron)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let runtime = job.runtime, let last = runtime.lastRun {
                Text(relative(last))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct CronAddSheet: View {
    @ObservedObject var store: JobStore
    @Binding var isPresented: Bool

    @State private var title: String = ""
    @State private var schedule: String = "0 9 * * *"
    @State private var prompt: String = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New cron prompt")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Morning briefing", text: $title)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Schedule (cron)").font(.caption).foregroundStyle(.secondary)
                TextField("0 9 * * *", text: $schedule)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { isPresented = false }
                Spacer()
                Button("Add") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !schedule.trimmingCharacters(in: .whitespaces).isEmpty &&
        !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = JobSlug.jobID(from: trimmedTitle)
        let spec = JobSpec(
            id: id,
            title: trimmedTitle,
            cron: schedule.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt,
            sinks: []
        )
        do {
            try store.add(spec)
            isPresented = false
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct JobSelection: Identifiable, Equatable {
    let id: String
}
