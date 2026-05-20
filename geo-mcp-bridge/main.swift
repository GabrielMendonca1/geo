import Foundation
import Network

let socketPath: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Application Support/Geo/mcp.sock").path
}()

guard FileManager.default.fileExists(atPath: socketPath) else {
    FileHandle.standardError.write(Data("Error: Geo MCP server not running (no socket at \(socketPath)). Launch Geo.app first.\n".utf8))
    exit(1)
}

let networkQueue = DispatchQueue(label: "geo.mcp.bridge.network", qos: .userInitiated)
let stdinQueue = DispatchQueue(label: "geo.mcp.bridge.stdin", qos: .userInitiated)

let endpoint = NWEndpoint.unix(path: socketPath)
let params = NWParameters()
params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
let connection = NWConnection(to: endpoint, using: params)

func readSocket() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { content, _, isComplete, error in
        if let data = content, !data.isEmpty {
            FileHandle.standardOutput.write(data)
        }
        if isComplete || error != nil {
            exit(0)
        }
        readSocket()
    }
}

func readStdin() {
    stdinQueue.async {
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty {
                connection.cancel()
                exit(0)
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    FileHandle.standardError.write(Data("Send error: \(error)\n".utf8))
                    exit(1)
                }
            })
        }
    }
}

connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        readSocket()
        readStdin()
    case .failed(let error):
        FileHandle.standardError.write(Data("Connection failed: \(error)\n".utf8))
        exit(1)
    case .cancelled:
        exit(0)
    default:
        break
    }
}

connection.start(queue: networkQueue)
dispatchMain()
