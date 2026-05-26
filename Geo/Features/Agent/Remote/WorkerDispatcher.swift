import Foundation
import os.log

private let dispatcherLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "geo", category: "WorkerDispatcher")

enum WorkerDispatchError: Error, LocalizedError {
    case workerOffline(String)
    case workerError(String)
    case timeout
    case unknown

    var errorDescription: String? {
        switch self {
        case .workerOffline(let name): return "\(name) is offline"
        case .workerError(let msg): return msg
        case .timeout: return "timeout"
        case .unknown: return "unknown error"
        }
    }
}

actor WorkerDispatcher {
    private let registry: WorkerSessionRegistry

    init(registry: WorkerSessionRegistry) {
        self.registry = registry
    }

    func dispatch(workerName: String, instruction: String, repo: String? = nil, timeoutSec: Int = 1800) async throws -> String {
        let session = await MainActor.run { registry.session(named: workerName) }
        guard let session else {
            throw WorkerDispatchError.workerOffline(workerName)
        }

        let dispatchId = UUID().uuidString
        var args: [String: AnyCodableValue] = [
            "id": .string(dispatchId),
            "instruction": .string(instruction),
            "timeoutSec": .int(timeoutSec)
        ]
        if let repo {
            args["repo"] = .string(repo)
        }

        do {
            let response = try await session.connection.sendRequest(method: "dispatch.run", params: args, timeout: 15)
            if let error = response.error {
                throw WorkerDispatchError.workerError(error.message)
            }
            dispatcherLogger.info("Dispatch \(dispatchId) sent to \(workerName)")
            return dispatchId
        } catch let err as WorkerDispatchError {
            throw err
        } catch let err as MCPConnectionError where err == .timeout {
            throw WorkerDispatchError.timeout
        } catch {
            dispatcherLogger.error("Dispatch \(dispatchId) failed: \(error.localizedDescription, privacy: .public)")
            throw WorkerDispatchError.workerError(error.localizedDescription)
        }
    }

    func cancel(workerName: String, dispatchId: String) async throws {
        let session = await MainActor.run { registry.session(named: workerName) }
        guard let session else {
            throw WorkerDispatchError.workerOffline(workerName)
        }
        let response = try await session.connection.sendRequest(
            method: "dispatch.cancel",
            params: ["id": .string(dispatchId)],
            timeout: 10
        )
        if let error = response.error {
            throw WorkerDispatchError.workerError(error.message)
        }
    }

    func onlineWorkerNames() async -> [String] {
        await MainActor.run { registry.sessions.map { $0.endpointName } }
    }
}

extension MCPConnectionError: Equatable {
    static func == (lhs: MCPConnectionError, rhs: MCPConnectionError) -> Bool {
        switch (lhs, rhs) {
        case (.timeout, .timeout), (.notConnected, .notConnected): return true
        case (.sendFailed, .sendFailed), (.encodeFailed, .encodeFailed): return true
        default: return false
        }
    }
}
