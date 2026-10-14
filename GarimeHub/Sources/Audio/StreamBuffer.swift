import Foundation
import os

protocol WindowSource: AnyObject {
    var duration: Double { get }
    func samples(from start: Double, to end: Double) -> [Float]
}

final class StreamBuffer: WindowSource {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var chunks: [[Float]] = []
    private var offsets: [Int] = []
    private var count = 0
    private let capacity: Int
    let sampleRate: Double

    init(sampleRate: Double, chunkSamples: Int = Config.streamChunkSamples) {
        self.sampleRate = sampleRate
        self.capacity = max(1, chunkSamples)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        os_unfair_lock_lock(lock)
        var index = 0
        while index < chunk.count {
            if chunks.isEmpty || chunks[chunks.count - 1].count >= capacity {
                var fresh: [Float] = []
                fresh.reserveCapacity(capacity)
                chunks.append(fresh)
                offsets.append(count + index)
            }
            let last = chunks.count - 1
            let room = capacity - chunks[last].count
            let take = min(room, chunk.count - index)
            chunks[last].append(contentsOf: chunk[index..<(index + take)])
            index += take
        }
        count += chunk.count
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        chunks.removeAll(keepingCapacity: true)
        offsets.removeAll(keepingCapacity: true)
        count = 0
        os_unfair_lock_unlock(lock)
    }

    var duration: Double {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Double(count) / sampleRate
    }

    func samples(from start: Double, to end: Double) -> [Float] {
        os_unfair_lock_lock(lock)
        let total = count
        let lower = max(0, min(total, Int(start * sampleRate)))
        let upper = max(lower, min(total, Int(end * sampleRate)))
        guard upper > lower else {
            os_unfair_lock_unlock(lock)
            return []
        }
        var pieces: [ArraySlice<Float>] = []
        var index = chunkIndex(containing: lower)
        while index < chunks.count, offsets[index] < upper {
            let base = offsets[index]
            let chunk = chunks[index]
            let low = max(lower, base) - base
            let high = min(upper, base + chunk.count) - base
            if high > low { pieces.append(chunk[low..<high]) }
            index += 1
        }
        os_unfair_lock_unlock(lock)

        var result: [Float] = []
        result.reserveCapacity(upper - lower)
        for piece in pieces { result.append(contentsOf: piece) }
        return result
    }

    private func chunkIndex(containing position: Int) -> Int {
        var low = 0
        var high = offsets.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if offsets[middle] <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }

    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let rate = UInt32(sampleRate)
        let dataBytes = UInt32(samples.count * 2)
        var output = Data(capacity: Int(dataBytes) + 44)

        func put(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }
        func put16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { output.append(contentsOf: $0) }
        }

        output.append(contentsOf: Array("RIFF".utf8))
        put(36 + dataBytes)
        output.append(contentsOf: Array("WAVEfmt ".utf8))
        put(16)
        put16(1)
        put16(1)
        put(rate)
        put(rate * 2)
        put16(2)
        put16(16)
        output.append(contentsOf: Array("data".utf8))
        put(dataBytes)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            put16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        try output.write(to: url, options: .atomic)
    }
}
