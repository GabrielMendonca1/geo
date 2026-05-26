import SwiftUI

struct ClawJobsSection: View {
    @EnvironmentObject private var service: NanoClawService
    @StateObject private var jobStore = JobStore()

    @State private var addJobPresented = false
    @State private var selectedJob: JobSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jobs")
                    .font(.headline)
                Spacer()
                Button {
                    addJobPresented = true
                } label: {
                    Label("Add job", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if jobStore.jobs.isEmpty {
                Text("No scheduled jobs. Add one to run prompts on a cron schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                NanoGridView(tiles: jobTiles) { tile in
                    if !tile.isAdder {
                        selectedJob = JobSelection(id: tile.id)
                    }
                }
            }
        }
        .onAppear { jobStore.refresh() }
        .onChange(of: service.crons) { _, _ in jobStore.refresh() }
        .sheet(isPresented: $addJobPresented) {
            JobDrawer(mode: .add, store: jobStore)
        }
        .sheet(item: $selectedJob) { sel in
            JobDrawer(mode: .view(id: sel.id), store: jobStore, runtimeLookup: runtime(for:))
        }
    }

    private func runtime(for id: String) -> JobRuntime? {
        service.crons.first(where: { $0.id == id })
    }

    private var jobTiles: [NanoTileModel] {
        jobStore.jobs.map { job in
            NanoTileModel(
                id: job.id,
                title: job.spec.title,
                subtitle: JobDrawer.cronToHumanReadable(job.spec.cron),
                icon: "clock.fill",
                tint: Color(red: 0.55, green: 0.40, blue: 0.93),
                statusDot: jobDotColor(runtime(for: job.id)),
                isAdder: false
            )
        }
    }

    private func jobDotColor(_ runtime: JobRuntime?) -> Color {
        guard let runtime else { return Color(white: 0.55) }
        switch runtime.lastStatus {
        case "ok": return Color(red: 0.18, green: 0.78, blue: 0.46)
        case "error": return Color(red: 0.95, green: 0.32, blue: 0.32)
        default: return Color(white: 0.55)
        }
    }
}

struct JobSelection: Identifiable, Equatable {
    let id: String
}
