import Foundation

@MainActor
final class AgentsViewModel: ObservableObject {
    @Published private(set) var dispatches: [DispatchItem] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var streamStatus: String?
    @Published private(set) var streamError: String?

    let client: BridgeClient

    init(client: BridgeClient = .shared) {
        self.client = client
    }

    func autoRefresh() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            dispatches = try await client.get("/dispatches")
            errorMessage = nil
        } catch {
            if Task.isCancelled { return }
            errorMessage = error.localizedDescription
        }
    }

    private var streamToken = 0
    private static let maxEvents = 2000

    func streamDetail(id: String) async {
        streamToken += 1
        let token = streamToken
        events = []
        streamStatus = nil
        streamError = nil
        var nextID = 0
        var pending: [AgentEvent] = []
        var lastFlush = ContinuousClock.now

        func flush() {
            guard !pending.isEmpty else { return }
            events.append(contentsOf: pending)
            pending = []
            if events.count > Self.maxEvents {
                events.removeFirst(events.count - Self.maxEvents)
            }
            lastFlush = .now
        }

        do {
            for try await message in client.stream("/dispatches/\(id)/stream") {
                if token != streamToken { return }
                if message.event == "done" {
                    let done = try? JSONDecoder().decode(StreamDone.self, from: Data(message.data.utf8))
                    flush()
                    streamStatus = done?.status ?? "done"
                    break
                }
                pending.append(contentsOf: AgentEvent.events(fromLogLine: message.data, nextID: &nextID))
                if pending.count >= 200 || ContinuousClock.now - lastFlush >= .milliseconds(100) {
                    flush()
                }
            }
            if token == streamToken {
                flush()
            }
        } catch {
            if Task.isCancelled || token != streamToken { return }
            flush()
            streamError = error.localizedDescription
        }
    }
}
