import Foundation

var passes = 0
var failures = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passes += 1
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)")
    }
}

func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) [got: \(lhs)]")
}

func pump(_ seconds: Double) {
    let limit = Date().addingTimeInterval(seconds)
    while Date() < limit {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

final class StubSource: WindowSource {
    private let lock = NSLock()
    private var seconds: Double
    private let rate: Double = 16000

    init(seconds: Double) {
        self.seconds = seconds
    }

    var duration: Double {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func samples(from start: Double, to end: Double) -> [Float] {
        let count = max(0, Int((end - start) * rate))
        return [Float](repeating: 0.02, count: count)
    }
}

final class ScriptedBackend: DecodeBackend {
    private let lock = NSLock()
    private var callCount = 0
    private var abortCount = 0
    private var fallbackCalls = 0
    private var wordsStorage: [SpokenWord]
    var alwaysFails = false
    var failsAfter: Int?
    var delay: TimeInterval = 0

    init(words: [SpokenWord]) {
        wordsStorage = words
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var fallbacks: Int {
        lock.lock()
        defer { lock.unlock() }
        return fallbackCalls
    }

    var aborts: Int {
        lock.lock()
        defer { lock.unlock() }
        return abortCount
    }

    func setWords(_ words: [SpokenWord]) {
        lock.lock()
        wordsStorage = words
        lock.unlock()
    }

    func decode(
        samples: [Float],
        windowStart: Double,
        prompt: String,
        timeout: TimeInterval,
        temperatureFallback: Bool
    ) throws -> [SpokenWord] {
        lock.lock()
        if temperatureFallback { fallbackCalls += 1 }
        callCount += 1
        let index = callCount
        let words = wordsStorage
        let fails = alwaysFails
        let threshold = failsAfter
        let pause = delay
        lock.unlock()

        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        if fails { throw DecodeError.failed("stub") }
        if let threshold, index > threshold { throw DecodeError.failed("stub tail") }
        return words
    }

    func abort() {
        lock.lock()
        abortCount += 1
        lock.unlock()
    }
}

func makeTuning() -> WindowedDecoder.Tuning {
    WindowedDecoder.Tuning(
        stepSeconds: 0.05,
        backoffSeconds: 0.2,
        minWindowSeconds: 0.1,
        margin: 0.7,
        agreementSteps: 2,
        overlapWords: 10,
        maxWindowSeconds: 12,
        maxStepFailures: 2,
        giveUpSeconds: 30,
        promptTailCharacters: 200,
        stepTimeout: 5,
        flushTimeout: 5
    )
}

let phrase = [
    SpokenWord(text: "ola", start: 0, end: 0.5),
    SpokenWord(text: "mundo", start: 0.5, end: 1.0),
]

print("== decoder: self-clocking commits ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.6)
    decoder.cancel()
    pump(0.1)

    equal(deltas, ["ola mundo"], "agreeing words are committed once as a single delta")
    equal(decoder.committedText, "ola mundo", "committed text matches the emitted deltas")
    check(backend.calls >= 2, "the loop keeps stepping [calls: \(backend.calls)]")
    check(backend.calls < 30, "the loop is self-clocking, not spinning [calls: \(backend.calls)]")
}

print("== decoder: no duplicate commits on repeated windows ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.8)
    decoder.cancel()
    pump(0.1)

    equal(deltas.count, 1, "re-decoding the same audio never re-emits committed words")
    let occurrences = decoder.committedText.components(separatedBy: "mundo").count - 1
    equal(occurrences, 1, "each word appears exactly once in the committed text")
}

print("== decoder: cancellation stops late typing ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    backend.delay = 0.2
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.05)
    decoder.cancel()
    let callsAtCancel = backend.calls
    pump(0.8)

    equal(deltas.count, 0, "a delta produced by an in-flight step is never delivered after cancel")
    check(backend.aborts >= 1, "cancel aborts the running decode")
    check(
        backend.calls <= callsAtCancel + 1,
        "no new decode starts after cancel [\(callsAtCancel) -> \(backend.calls)]"
    )
    equal(decoder.committedText, "", "nothing is committed once cancelled")
}

print("== decoder: cancel after commits blocks further deltas ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.4)
    let before = deltas.count
    decoder.cancel()
    backend.setWords(phrase + [SpokenWord(text: "extra", start: 1.0, end: 1.5)])
    pump(0.5)
    equal(deltas.count, before, "no delta arrives after cancel")
    check(!decoder.committedText.contains("extra"), "text decoded after cancel is never committed")
}

print("== decoder: failure escalation ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    backend.alwaysFails = true
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var lost = 0
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.onStreamingLost = { lost += 1 }
    decoder.start()
    pump(0.6)

    equal(lost, 1, "streaming loss is reported exactly once")
    equal(backend.calls, 2, "the loop stops after the configured failure budget")
    equal(deltas.count, 0, "a failing backend emits nothing")
    decoder.cancel()
    pump(0.1)
}

print("== decoder: final flush ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.4)
    equal(decoder.committedText, "ola mundo", "streaming committed before the flush")

    backend.setWords(phrase + [SpokenWord(text: "cruel", start: 1.0, end: 1.5)])
    let callsBeforeFlush = backend.calls
    var flushes = 0
    var tail = ""
    var flushFailed = true
    decoder.finish { value, failed in
        flushes += 1
        tail = value
        flushFailed = failed
    }
    pump(0.5)

    equal(flushes, 1, "the flush completion fires exactly once")
    equal(tail, " cruel", "the flush returns only what was not committed yet")
    check(!flushFailed, "a healthy flush is not reported as failed")
    equal(decoder.committedText, "ola mundo cruel", "the flush appends without duplicating")
    check(
        backend.calls <= callsBeforeFlush + 2,
        "the flush runs one final decode [\(callsBeforeFlush) -> \(backend.calls)]"
    )
    check(backend.aborts >= 1, "the flush aborts any in-flight step first")
}

print("== decoder: flush failure is reported ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    decoder.start()
    pump(0.4)
    backend.failsAfter = backend.calls
    var tail = "unset"
    var flushFailed = false
    decoder.finish { value, failed in
        tail = value
        flushFailed = failed
    }
    pump(0.5)
    equal(tail, "", "a failed flush returns no tail")
    check(flushFailed, "a failed flush is reported so the batch fallback can run")
    equal(decoder.committedText, "ola mundo", "a failed flush leaves committed text untouched")
}

print("== decoder: flush after cancel decodes nothing ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    decoder.start()
    pump(0.3)
    decoder.cancel()
    let callsAtCancel = backend.calls
    var flushes = 0
    var tail = "unset"
    decoder.finish { value, _ in
        flushes += 1
        tail = value
    }
    pump(0.4)
    equal(flushes, 1, "the completion still fires after a cancelled session")
    equal(tail, "", "a cancelled session flushes no text")
    check(
        backend.calls <= callsAtCancel + 1,
        "no final decode runs after cancel [\(callsAtCancel) -> \(backend.calls)]"
    )
}

print("== decoder: start is idempotent and post-cancel start is refused ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    decoder.start()
    decoder.start()
    pump(0.3)
    decoder.cancel()
    pump(0.1)
    let after = backend.calls
    decoder.start()
    pump(0.3)
    equal(backend.calls, after, "a cancelled decoder cannot be restarted")
}

print("== flush guard: degenerate tails are rejected ==")
let loopPhrase = "e se inscreve no canal"
let hallucination = Array(repeating: loopPhrase, count: 37).joined(separator: " ")
check(
    FlushGuard.rejection(tail: hallucination, windowSeconds: 60) != nil,
    "the 37x 'e se inscreve no canal' loop is rejected"
)
check(
    FlushGuard.rejection(tail: Array(repeating: loopPhrase, count: 6).joined(separator: " "), windowSeconds: 40) != nil,
    "a short repetition loop inside the word budget is still rejected"
)
let long165 = (1...165).map { "palavra\($0)" }.joined(separator: " ")
check(
    FlushGuard.rejection(tail: long165, windowSeconds: 40) != nil,
    "a 165 word flush tail is rejected by the absolute cap"
)
let long110 = (1...110).map { "termo\($0)" }.joined(separator: " ")
check(
    FlushGuard.rejection(tail: long110, windowSeconds: 60) != nil,
    "a 110 word flush tail is rejected by the absolute cap"
)
let fast40 = (1...40).map { "rapido\($0)" }.joined(separator: " ")
equal(
    FlushGuard.rejection(tail: fast40, windowSeconds: 3),
    .tooFast(words: 40, seconds: 3),
    "40 words in a 3s window exceed the plausible speech rate"
)
check(
    FlushGuard.rejection(tail: "e isso e tudo por hoje obrigado", windowSeconds: 3) == nil,
    "a healthy short tail is accepted"
)
check(
    FlushGuard.rejection(tail: "entao a gente vai testar o ditado continuo em portugues agora mesmo", windowSeconds: 5) == nil,
    "a healthy longer tail is accepted"
)
check(
    FlushGuard.rejection(tail: "muito muito muito bom", windowSeconds: 3) == nil,
    "a natural word repetition is not treated as a loop"
)
check(
    FlushGuard.rejection(tail: "", windowSeconds: 3) == nil,
    "an empty tail is not a rejection"
)

print("== decoder: a degenerate flush is never committed ==")
do {
    let source = StubSource(seconds: 5.0)
    var loopWords: [SpokenWord] = []
    let pieces = hallucination.split(separator: " ").map(String.init)
    for (index, word) in pieces.enumerated() {
        let at = 5.0 * Double(index) / Double(pieces.count)
        loopWords.append(SpokenWord(text: word, start: at, end: at + 0.02))
    }
    let backend = ScriptedBackend(words: loopWords)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var tail = "unset"
    var flushFailed = false
    decoder.finish { value, failed in
        tail = value
        flushFailed = failed
    }
    pump(0.4)
    equal(tail, "", "a hallucinated flush delivers no text")
    check(flushFailed, "a hallucinated flush is reported as failed so the review batch runs")
    equal(decoder.committedText, "", "a rejected flush never enters the committed text")
    decoder.cancel()
}

print("== decoder: a healthy flush still commits ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var tail = "unset"
    var flushFailed = true
    decoder.finish { value, failed in
        tail = value
        flushFailed = failed
    }
    pump(0.4)
    equal(tail, "ola mundo", "a plausible flush is delivered")
    check(!flushFailed, "a plausible flush is not reported as failed")
    equal(backend.fallbacks, 1, "the flush decode asks for temperature fallback")
    decoder.cancel()
}

print("== decoder: step decodes keep temperature fallback off ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    decoder.start()
    pump(0.4)
    check(backend.calls >= 2, "steps ran [calls: \(backend.calls)]")
    equal(backend.fallbacks, 0, "no step decode enables temperature fallback")
    decoder.cancel()
    pump(0.1)
}

print("== decoder: dropping the last reference stops the loop ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    var tuning = makeTuning()
    tuning.stepSeconds = 0.3
    var orphan: WindowedDecoder? = WindowedDecoder(source: source, backend: backend, tuning: tuning)
    orphan?.start()
    pump(0.1)
    let before = backend.calls
    check(before >= 1, "the decoder really was stepping before the drop [calls: \(before)]")
    orphan = nil
    pump(1.5)
    equal(backend.calls, before, "no decode runs after the last reference is dropped without cancel")
}

func loopingWords(_ phraseText: String, repeats: Int, over seconds: Double) -> [SpokenWord] {
    let pieces = Array(repeating: phraseText, count: repeats)
        .joined(separator: " ")
        .split(separator: " ")
        .map(String.init)
    return pieces.enumerated().map { index, word in
        let at = seconds * Double(index) / Double(pieces.count)
        return SpokenWord(text: word, start: at, end: at + 0.02)
    }
}

print("== decoder: a degenerate loop is never committed mid-stream ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: loopingWords(loopPhrase, repeats: 12, over: 3.0))
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.6)
    check(backend.calls >= 2, "the degenerate backend really was polled [calls: \(backend.calls)]")
    decoder.cancel()
    pump(0.1)

    equal(deltas, [], "a looping hallucination is never emitted as a streaming delta")
    equal(decoder.committedText, "", "a looping hallucination never enters the committed text")
}

print("== decoder: a healthy stream is not mistaken for a loop ==")
do {
    let source = StubSource(seconds: 5.0)
    let sentence = "entao a gente vai testar o ditado"
    let spoken = sentence.split(separator: " ").enumerated().map { index, word in
        SpokenWord(text: String(word), start: Double(index) * 0.3, end: Double(index) * 0.3 + 0.28)
    }
    let backend = ScriptedBackend(words: spoken)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(0.6)
    decoder.cancel()
    pump(0.1)

    check(!deltas.isEmpty, "a plausible window still commits [\(deltas)]")
    equal(decoder.committedText, sentence, "the whole plausible window is committed verbatim")
}

print("== decoder: a natural repetition inside a window still commits ==")
do {
    let source = StubSource(seconds: 5.0)
    let sentence = "muito muito muito bom mesmo"
    let spoken = sentence.split(separator: " ").enumerated().map { index, word in
        SpokenWord(text: String(word), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
    }
    let backend = ScriptedBackend(words: spoken)
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    decoder.start()
    pump(0.5)
    decoder.cancel()
    pump(0.1)
    equal(decoder.committedText, sentence, "a natural repetition is not treated as a hallucination loop")
}

print("== decoder: an abandoned decoder aborts its backend ==")
do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    var orphan: WindowedDecoder? = WindowedDecoder(source: source, backend: backend, tuning: makeTuning())
    check(orphan != nil, "the orphan decoder exists")
    equal(backend.aborts, 0, "a decoder that was never dropped has not aborted anything")
    orphan = nil
    equal(backend.aborts, 1, "dropping a decoder aborts its backend exactly once")
}

do {
    let source = StubSource(seconds: 5.0)
    let backend = ScriptedBackend(words: phrase)
    var tuning = makeTuning()
    tuning.stepSeconds = 0.3
    var orphan: WindowedDecoder? = WindowedDecoder(source: source, backend: backend, tuning: tuning)
    orphan?.start()
    pump(0.1)
    check(backend.calls >= 1, "the abandoned decoder really was stepping [calls: \(backend.calls)]")
    orphan = nil
    pump(0.5)
    check(backend.aborts >= 1, "abandoning a running decoder aborts its backend [aborts: \(backend.aborts)]")
}

print("== stream buffer: chunked slicing ==")
do {
    let buffer = StreamBuffer(sampleRate: 10, chunkSamples: 4)
    equal(buffer.duration, 0, "an empty buffer has no duration")
    equal(buffer.samples(from: 0, to: 1), [], "an empty buffer yields no samples")
    buffer.append((0..<10).map { Float($0) })
    equal(buffer.duration, 1.0, "duration follows the sample count")
    equal(buffer.samples(from: 0, to: 1.0), (0..<10).map { Float($0) }, "the whole buffer round-trips across chunks")
    equal(buffer.samples(from: 0.5, to: 0.8), [5, 6, 7], "a range spanning two chunks is joined correctly")
    equal(buffer.samples(from: 0.4, to: 0.6), [4, 5], "a range inside a single chunk is exact")
    equal(buffer.samples(from: 0.8, to: 5.0), [8, 9], "a range past the end clamps to what exists")
    equal(buffer.samples(from: 2.0, to: 3.0), [], "a range entirely past the end is empty")
    equal(buffer.samples(from: 0.5, to: 0.5), [], "an empty range yields nothing")
    equal(buffer.samples(from: 0.9, to: 0.1), [], "an inverted range yields nothing")
    buffer.append([Float(10)])
    equal(buffer.samples(from: 0.9, to: 1.1), [9, 10], "appending after a chunk boundary keeps the sequence")
    buffer.reset()
    equal(buffer.duration, 0, "reset empties the buffer")
    equal(buffer.samples(from: 0, to: 1), [], "reset drops every chunk")
    buffer.append([Float(1), 2, 3])
    equal(buffer.samples(from: 0, to: 0.3), [1, 2, 3], "the buffer is reusable after reset")
}
do {
    let buffer = StreamBuffer(sampleRate: 16000)
    for _ in 0..<100 { buffer.append([Float](repeating: 0.5, count: 1470)) }
    equal(buffer.duration, Double(147000) / 16000, "many small appends accumulate exactly")
    let slice = buffer.samples(from: 1.0, to: 3.0)
    equal(slice.count, 32000, "a two second slice has the right length")
    check(slice.allSatisfy { $0 == 0.5 }, "sliced values survive chunking intact")
}

print("== stream buffer: the capture thread is never blocked by a reader ==")
do {
    let buffer = StreamBuffer(sampleRate: Config.streamSampleRate)
    let block = [Float](repeating: 0.25, count: 512)
    for _ in 0..<2400 { buffer.append(block) }
    equal(buffer.duration, Double(2400 * 512) / Config.streamSampleRate, "the contention fixture is 76.8s of audio")

    let stop = NSLock()
    var running = true
    var readerRounds = 0
    let reader = Thread {
        while true {
            stop.lock()
            let keepGoing = running
            stop.unlock()
            if !keepGoing { break }
            let slice = buffer.samples(from: 0, to: 76.0)
            if slice.count > 0 { readerRounds += 1 }
        }
    }
    reader.qualityOfService = .utility
    reader.start()

    var worst = 0.0
    var total = 0.0
    let capture = DispatchQueue(label: "capture", qos: .userInteractive)
    let finished = DispatchSemaphore(value: 0)
    capture.async {
        for _ in 0..<600 {
            let began = Date()
            buffer.append(block)
            let cost = Date().timeIntervalSince(began)
            worst = max(worst, cost)
            total += cost
            Thread.sleep(forTimeInterval: 0.0005)
        }
        finished.signal()
    }
    _ = finished.wait(timeout: .now() + 30)
    stop.lock()
    running = false
    stop.unlock()
    while !reader.isFinished { usleep(1000) }

    check(readerRounds > 0, "the reader really was copying the whole buffer [rounds: \(readerRounds)]")
    check(
        worst < 0.010,
        "no append waits on a multi-megabyte read [worst: \(String(format: "%.4f", worst))s over 600 appends]"
    )
    check(
        total / 600 < 0.0005,
        "the average append stays in the microsecond range [avg: \(String(format: "%.6f", total / 600))s]"
    )
    let tail = buffer.samples(from: 76.8, to: 96.0)
    check(tail.allSatisfy { $0 == 0.25 }, "concurrent appends and reads never corrupt the buffer")
    equal(tail.count, 600 * 512, "every concurrent append landed exactly once")
}

print("== decoder: a window that never agrees still commits ==")
do {
    final class DriftingBackend: DecodeBackend {
        private let lock = NSLock()
        private var index = 0
        private(set) var windows: [Double] = []

        func decode(
            samples: [Float],
            windowStart: Double,
            prompt: String,
            timeout: TimeInterval,
            temperatureFallback: Bool
        ) throws -> [SpokenWord] {
            let span = Double(samples.count) / 16000
            lock.lock()
            index += 1
            let round = index
            windows.append(span)
            lock.unlock()
            var words: [SpokenWord] = []
            var cursor = 0.0
            while cursor + 0.5 <= span {
                words.append(SpokenWord(
                    text: "p\(round)x\(words.count)",
                    start: windowStart + cursor,
                    end: windowStart + cursor + 0.5
                ))
                cursor += 0.5
            }
            return words
        }

        func abort() {}
    }

    final class GrowingSource: WindowSource {
        private let lock = NSLock()
        private let started = Date()
        private let pace: Double

        init(pace: Double) {
            self.pace = pace
        }

        var duration: Double {
            lock.lock()
            defer { lock.unlock() }
            return min(20, Date().timeIntervalSince(started) * pace)
        }

        func samples(from start: Double, to end: Double) -> [Float] {
            [Float](repeating: 0.02, count: max(0, Int((end - start) * 16000)))
        }
    }

    var tuning = makeTuning()
    tuning.maxWindowSeconds = 3
    tuning.margin = 0.2
    tuning.stepSeconds = 0.05
    let source = GrowingSource(pace: 12)
    let backend = DriftingBackend()
    let decoder = WindowedDecoder(source: source, backend: backend, tuning: tuning)
    var deltas: [String] = []
    decoder.onDelta = { deltas.append($0) }
    decoder.start()
    pump(1.2)
    decoder.cancel()
    check(!deltas.isEmpty, "the cap forces a commit even when no two decodes agree")
    let steady = backend.windows.suffix(5)
    let worst = steady.max() ?? 0
    check(
        worst <= tuning.maxWindowSeconds + 1.5,
        "the window settles at the cap instead of growing [worst of last 5: \(String(format: "%.1f", worst))s]"
    )
}

print("== stabilizer: forced commit respects the cut ==")
do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    let words = [
        SpokenWord(text: "um", start: 0.0, end: 0.5),
        SpokenWord(text: "dois", start: 0.5, end: 1.0),
        SpokenWord(text: "tres", start: 1.0, end: 4.0),
    ]
    let delta = stabilizer.forceCommit(words: words, windowStart: 0, cut: 2.0)
    equal(delta, "um dois", "only words that end before the cut are committed")
    check(stabilizer.commitTime >= 1.0, "the commit clock moves with the forced commit")
    equal(
        stabilizer.forceCommit(words: words, windowStart: 0, cut: 0.2),
        "",
        "nothing is committed when the cut lands before the first word"
    )
}

print("")
print("decoder passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
