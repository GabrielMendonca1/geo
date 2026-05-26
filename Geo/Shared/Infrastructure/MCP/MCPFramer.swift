import Foundation

final class MCPFramer {
    enum FeedResult {
        case frames([Data])
        case overflow
    }

    private var buffer = Data()
    private let maxBufferSize: Int

    init(maxBufferSize: Int = 1_048_576) {
        self.maxBufferSize = maxBufferSize
    }

    func feed(_ data: Data) -> FeedResult {
        buffer.append(data)

        if buffer.count > maxBufferSize {
            buffer.removeAll()
            return .overflow
        }

        var frames: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[buffer.index(after: newlineIndex)...])

            guard !lineData.isEmpty else { continue }
            let trimmed = lineData.filter { $0 != UInt8(ascii: "\r") }
            guard !trimmed.isEmpty else { continue }
            frames.append(Data(trimmed))
        }
        return .frames(frames)
    }

    static func encodeFrame(_ payload: Data) -> Data {
        var out = payload
        out.append(contentsOf: "\n".utf8)
        return out
    }
}
