import Foundation
import IOKit.pwr_mgt

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

func words(_ items: [(String, Double, Double)]) -> [SpokenWord] {
    items.map { SpokenWord(text: $0.0, start: $0.1, end: $0.2) }
}

print("== stabilizer: local agreement ==")
do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.7, overlapWords: 10)
    let first = stabilizer.step(words: words([("ola", 0, 0.5), ("mundo", 0.5, 1.0)]), windowEnd: 3.0)
    equal(first, "", "one observation commits nothing")
    let second = stabilizer.step(words: words([("ola", 0, 0.5), ("mundo", 0.5, 1.0)]), windowEnd: 3.0)
    equal(second, "ola mundo", "two agreeing observations commit")
    equal(stabilizer.commitTime, 1.0, "commit time advances to the last committed word")
}

do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.7, overlapWords: 10)
    let script = words([("um", 0, 0.5), ("dois", 2.5, 2.9)])
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    let delta = stabilizer.step(words: script, windowEnd: 3.0)
    equal(delta, "um", "word inside the commit margin is held back")
}

do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.7, overlapWords: 10)
    let disagreeing = [
        words([("ola", 0, 0.5), ("mundo", 0.5, 1.0)]),
        words([("ola", 0, 0.5), ("mundos", 0.5, 1.0)]),
    ]
    _ = stabilizer.step(words: disagreeing[0], windowEnd: 3.0)
    let delta = stabilizer.step(words: disagreeing[1], windowEnd: 3.0)
    equal(delta, "ola", "only the agreeing prefix is committed")
}

print("== stabilizer: commit boundary lands in silence ==")
do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    let script = words([("um", 0, 0.5), ("dois", 1.5, 1.9), ("tres", 2.6, 3.0)])
    _ = stabilizer.step(words: script, windowEnd: 2.4)
    _ = stabilizer.step(words: script, windowEnd: 2.4)
    check(
        stabilizer.commitTime > 1.9 && stabilizer.commitTime < 2.6,
        "the commit boundary is snapped into the silence between words [got: \(stabilizer.commitTime)]"
    )
    equal(stabilizer.committedText, "um dois", "words before the margin are committed")
}
do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    let script = words([("um", 0, 0.5), ("dois", 0.5, 1.0)])
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    equal(stabilizer.commitTime, 1.0, "with no following word the boundary stays at the last word end")
}

print("== stabilizer: anchored window simulation ==")

let truth: [(String, Double, Double)] = [
    ("isso", 0.0, 0.4), ("aqui", 0.4, 0.8), ("é", 0.8, 1.0), ("um", 1.0, 1.3),
    ("teste", 1.3, 1.8), ("de", 1.8, 2.0), ("ditado", 2.0, 2.6), ("contínuo", 2.6, 3.2),
    ("em", 3.2, 3.4), ("português", 3.4, 4.2), ("agora", 4.2, 4.8), ("mesmo", 4.8, 5.4),
]

func simulate(jitter: Double, backoff: Double, step: Double, margin: Double)
    -> (text: String, deltas: [String], monotone: Bool, exact: Bool, tail: String) {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: margin, overlapWords: 6)
    var now = 1.0
    var previous = ""
    var monotone = true
    var exact = true
    var deltas: [String] = []
    var wobble = 0.0
    while now <= 7.0 {
        let windowStart = max(stabilizer.commitTime - backoff, 0)
        wobble = wobble == 0 ? jitter : -jitter
        let visible = truth
            .filter { $0.2 > windowStart && $0.1 < now }
            .map { entry in
                SpokenWord(
                    text: entry.0,
                    start: max(entry.1 + wobble, windowStart),
                    end: min(entry.2 + wobble, now)
                )
            }
        let delta = stabilizer.step(words: visible, windowEnd: now)
        if !stabilizer.committedText.hasPrefix(previous) { monotone = false }
        if stabilizer.committedText != previous + delta { exact = false }
        if !delta.isEmpty { deltas.append(delta) }
        previous = stabilizer.committedText
        now += step
    }

    let flushStart = max(stabilizer.commitTime - backoff, 0)
    let pending = truth
        .filter { $0.2 > flushStart }
        .map(\.0)
        .joined(separator: " ")
    let tail = stabilizer.commitFinal(pending)
    if !stabilizer.committedText.hasPrefix(previous) { monotone = false }
    if stabilizer.committedText != previous + tail { exact = false }
    return (stabilizer.committedText, deltas, monotone, exact, tail)
}

do {
    let run = simulate(jitter: 0, backoff: 0.2, step: 1.5, margin: 0.5)
    check(run.monotone, "committed text always keeps the previous text as a prefix")
    check(run.exact, "committed text is exactly the concatenation of every emitted delta")
    check(run.deltas.count >= 2, "text arrives incrementally, not in one lump [\(run.deltas.count)]")
    var duplicated: [String] = []
    for entry in truth {
        let occurrences = run.text.components(separatedBy: entry.0).count - 1
        if occurrences > 1 { duplicated.append(entry.0) }
    }
    equal(duplicated, [], "no word is committed twice across anchored re-decodes")
    var absent: [String] = []
    for entry in truth where !run.text.contains(entry.0) { absent.append(entry.0) }
    equal(absent, [], "every spoken word survives streaming plus the final flush")
    check(!run.tail.isEmpty, "the final flush delivers the words held back by the margin")
}

do {
    let run = simulate(jitter: 0.12, backoff: 0.2, step: 1.5, margin: 0.5)
    check(run.monotone, "timestamp jitter never rewrites committed text")
    check(run.exact, "timestamp jitter never desynchronizes deltas from committed text")
    var duplicated: [String] = []
    var missing: [String] = []
    for entry in truth {
        let occurrences = run.text.components(separatedBy: entry.0).count - 1
        if occurrences > 1 { duplicated.append(entry.0) }
        if occurrences == 0 { missing.append(entry.0) }
    }
    equal(duplicated, [], "jittered timestamps do not duplicate words")
    equal(missing, [], "jittered timestamps do not drop words at the window seam")
}

do {
    let slow = simulate(jitter: 0, backoff: 0.2, step: 3.0, margin: 0.5)
    check(slow.monotone, "a slower step cadence still never rewrites")
    var duplicated: [String] = []
    var missing: [String] = []
    for entry in truth {
        let occurrences = slow.text.components(separatedBy: entry.0).count - 1
        if occurrences > 1 { duplicated.append(entry.0) }
        if occurrences == 0 { missing.append(entry.0) }
    }
    equal(duplicated, [], "a slower step cadence does not duplicate at the seam")
    equal(missing, [], "a slower step cadence does not drop words")
}

print("== stabilizer: production seam with a truncated word ==")

let seamTruth: [(String, Double, Double)] = [
    ("eu", 0.00, 0.30), ("vou", 0.34, 0.80), ("pra", 0.84, 1.30), ("minha", 1.34, 1.95),
    ("casa", 2.00, 2.70), ("e", 3.10, 3.30), ("grande", 3.34, 4.10), ("mesmo", 4.50, 5.10),
    ("bonita", 5.14, 5.90), ("demais", 6.30, 7.00),
]

func seamVisible(windowStart: Double, now: Double) -> [SpokenWord] {
    var visible: [SpokenWord] = []
    for entry in seamTruth {
        guard entry.2 > windowStart + 1e-9, entry.1 < now else { continue }
        if entry.1 < windowStart - 1e-9 {
            let characters = Array(entry.0)
            let fragment = String(characters.suffix(max(1, characters.count / 2)))
            visible.append(SpokenWord(text: fragment, start: windowStart, end: entry.2))
        } else {
            visible.append(SpokenWord(text: entry.0, start: entry.1, end: min(entry.2, now)))
        }
    }
    return visible
}

func simulateSeam(anchored: Bool, backoff: Double, step: Double, margin: Double)
    -> (text: String, deltas: [String], monotone: Bool, exact: Bool) {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: margin, overlapWords: 6)
    var now = step
    var previous = ""
    var monotone = true
    var exact = true
    var deltas: [String] = []
    while now <= 9.0 {
        let windowStart = anchored
            ? stabilizer.anchoredWindowStart(backoff: backoff)
            : max(stabilizer.commitTime - backoff, 0)
        let delta = stabilizer.step(words: seamVisible(windowStart: windowStart, now: now), windowEnd: now)
        if !stabilizer.committedText.hasPrefix(previous) { monotone = false }
        if stabilizer.committedText != previous + delta { exact = false }
        if !delta.isEmpty { deltas.append(delta) }
        previous = stabilizer.committedText
        now += step
    }
    let flushStart = anchored
        ? stabilizer.anchoredWindowStart(backoff: backoff)
        : max(stabilizer.commitTime - backoff, 0)
    let pending = seamVisible(windowStart: flushStart, now: 9.0).map(\.text).joined(separator: " ")
    let tail = stabilizer.commitFinal(pending)
    if !stabilizer.committedText.hasPrefix(previous) { monotone = false }
    if stabilizer.committedText != previous + tail { exact = false }
    return (stabilizer.committedText, deltas, monotone, exact)
}

func seamReport(_ text: String) -> (junk: [String], duplicated: [String], missing: [String]) {
    let vocabulary = Set(seamTruth.map { Stabilizer.normalize($0.0) })
    let produced = text.split(whereSeparator: \.isWhitespace).map { Stabilizer.normalize(String($0)) }
    let junk = produced.filter { !vocabulary.contains($0) }
    var duplicated: [String] = []
    var missing: [String] = []
    for entry in seamTruth {
        let key = Stabilizer.normalize(entry.0)
        let occurrences = produced.filter { $0 == key }.count
        if occurrences > 1 { duplicated.append(entry.0) }
        if occurrences == 0 { missing.append(entry.0) }
    }
    return (junk, duplicated, missing)
}

do {
    let unanchored = simulateSeam(anchored: false, backoff: 1.0, step: 1.5, margin: 0.5)
    let report = seamReport(unanchored.text)
    check(
        !report.junk.isEmpty || !report.duplicated.isEmpty,
        "the simulation really reproduces the seam defect without the anchor [\(unanchored.text)]"
    )
}

do {
    let run = simulateSeam(anchored: true, backoff: 1.0, step: 1.5, margin: 0.5)
    let report = seamReport(run.text)
    check(run.monotone, "the anchored seam never rewrites committed text")
    check(run.exact, "the anchored seam keeps deltas equal to the committed text")
    check(run.deltas.count >= 2, "the anchored seam still delivers incrementally [\(run.deltas.count)]")
    equal(report.junk, [], "no truncated fragment survives at production tuning [\(run.text)]")
    equal(report.duplicated, [], "no word is duplicated at the seam at production tuning")
    equal(report.missing, [], "no word is lost at the seam at production tuning")
}

do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    _ = stabilizer.step(words: words([("um", 0, 0.5), ("dois", 1.5, 1.9), ("tres", 2.6, 3.0)]), windowEnd: 2.4)
    _ = stabilizer.step(words: words([("um", 0, 0.5), ("dois", 1.5, 1.9), ("tres", 2.6, 3.0)]), windowEnd: 2.4)
    let anchored = stabilizer.anchoredWindowStart(backoff: 1.0)
    check(
        anchored >= 0.5 && anchored <= 1.5,
        "the window start snaps back into the silence before 'dois' [got: \(anchored)]"
    )
    let far = stabilizer.anchoredWindowStart(backoff: 8.0)
    equal(far, 0, "a backoff past the beginning stays at zero")
}

do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    var at = 0.0
    for index in 0..<400 {
        let script = words([
            ("w\(index)", at, at + 0.2),
            ("x\(index)", at + 0.25, at + 0.45),
            ("y\(index)", at + 0.5, at + 0.7),
        ])
        _ = stabilizer.step(words: script, windowEnd: at + 1.4)
        _ = stabilizer.step(words: script, windowEnd: at + 1.4)
        at += 0.75
    }
    let start = stabilizer.anchoredWindowStart(backoff: 1.0)
    check(
        start > stabilizer.commitTime - 1.7 && start <= stabilizer.commitTime,
        "retained boundaries stay near the head of a long recording [got: \(start)]"
    )
    check(
        stabilizer.retainedBoundaryCount <= Config.seamMaxRetainedBoundaries,
        "retained boundaries are pruned [got: \(stabilizer.retainedBoundaryCount)]"
    )
}

print("== stabilizer: contiguous whisper timings at the window seam ==")

let contiguousTruth: [(String, Double, Double)] = [
    ("eu", 0.00, 0.30), ("vou", 0.30, 0.78), ("pra", 0.78, 1.20), ("minha", 1.20, 1.85),
    ("casa", 1.85, 2.60), ("agora", 2.60, 3.20), ("mesmo", 3.20, 3.90), ("porque", 3.90, 4.60),
    ("esta", 4.60, 5.10), ("chovendo", 5.10, 5.95), ("muito", 5.95, 6.50), ("forte", 6.50, 7.20),
    ("aqui", 7.20, 7.80), ("fora", 7.80, 8.50),
]

func contiguousVisible(windowStart: Double, now: Double, jitter: Double) -> [SpokenWord] {
    var visible: [SpokenWord] = []
    for entry in contiguousTruth {
        guard entry.2 > windowStart + 1e-9, entry.1 < now else { continue }
        if entry.1 < windowStart - 1e-9 {
            visible.append(SpokenWord(text: "e", start: windowStart, end: windowStart + 0.12))
            continue
        }
        visible.append(SpokenWord(
            text: entry.0,
            start: max(entry.1 + jitter, windowStart),
            end: min(entry.2 + jitter, now)
        ))
    }
    return visible
}

func simulateContiguous(anchored: Bool, jitter: Double)
    -> (text: String, deltas: [String], monotone: Bool, exact: Bool) {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    var now = 1.5
    var previous = ""
    var monotone = true
    var exact = true
    var deltas: [String] = []
    var wobble = 0.0
    while now <= 10.0 {
        wobble = wobble == 0 ? jitter : -jitter
        let windowStart = anchored
            ? stabilizer.anchoredWindowStart(backoff: 1.0)
            : max(stabilizer.commitTime - 1.0, 0)
        let visible = contiguousVisible(windowStart: windowStart, now: now, jitter: wobble)
        let delta = stabilizer.step(words: visible, windowStart: windowStart, windowEnd: now)
        if !stabilizer.committedText.hasPrefix(previous) { monotone = false }
        if stabilizer.committedText != previous + delta { exact = false }
        if !delta.isEmpty { deltas.append(delta) }
        previous = stabilizer.committedText
        now += 1.5
    }
    let flushStart = anchored
        ? stabilizer.anchoredWindowStart(backoff: 1.0)
        : max(stabilizer.commitTime - 1.0, 0)
    let pending = contiguousVisible(windowStart: flushStart, now: 10.0, jitter: 0)
        .map(\.text)
        .joined(separator: " ")
    let tail = stabilizer.commitFinal(pending)
    if !stabilizer.committedText.hasPrefix(previous) { monotone = false }
    if stabilizer.committedText != previous + tail { exact = false }
    return (stabilizer.committedText, deltas, monotone, exact)
}

func contiguousReport(_ text: String) -> (junk: [String], duplicated: [String], missing: [String]) {
    let vocabulary = Set(contiguousTruth.map { Stabilizer.normalize($0.0) })
    let produced = text.split(whereSeparator: \.isWhitespace).map { Stabilizer.normalize(String($0)) }
    let junk = produced.filter { !vocabulary.contains($0) }
    var duplicated: [String] = []
    var missing: [String] = []
    for entry in contiguousTruth {
        let key = Stabilizer.normalize(entry.0)
        let occurrences = produced.filter { $0 == key }.count
        if occurrences > 1 { duplicated.append(entry.0) }
        if occurrences == 0 { missing.append(entry.0) }
    }
    return (junk, duplicated, missing)
}

do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.5, overlapWords: 6)
    let script = words([
        ("um", 0, 0.5), ("dois", 0.5, 1.0), ("tres", 1.0, 1.5),
        ("quatro", 1.5, 2.0), ("cinco", 2.0, 2.6),
    ])
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    check(
        stabilizer.retainedBoundaryCount > 0,
        "word onsets are retained even when whisper reports no silence between words [got: \(stabilizer.retainedBoundaryCount)]"
    )
    let anchored = stabilizer.anchoredWindowStart(backoff: 1.0)
    let onsets = [0.5, 1.0, 1.5, 2.0]
    check(
        onsets.contains(where: { abs($0 - anchored) < 1e-6 }),
        "the window start snaps onto a word onset, never into the middle of a word [got: \(anchored)]"
    )
}

do {
    let unanchored = simulateContiguous(anchored: false, jitter: 0)
    let report = contiguousReport(unanchored.text)
    check(
        !report.junk.isEmpty || !report.missing.isEmpty,
        "the contiguous simulation reproduces the seam defect without a working anchor [\(unanchored.text)]"
    )
}

do {
    let run = simulateContiguous(anchored: true, jitter: 0)
    let report = contiguousReport(run.text)
    check(run.monotone, "the contiguous seam never rewrites committed text")
    check(run.exact, "the contiguous seam keeps deltas equal to the committed text")
    check(run.deltas.count >= 2, "the contiguous seam still delivers incrementally [\(run.deltas.count)]")
    equal(report.junk, [], "no leading fragment is committed on contiguous timings [\(run.text)]")
    equal(report.missing, [], "no word is lost at a contiguous seam [\(run.text)]")
    equal(report.duplicated, [], "no word is duplicated at a contiguous seam [\(run.text)]")
}

do {
    let run = simulateContiguous(anchored: true, jitter: 0.09)
    let report = contiguousReport(run.text)
    check(run.monotone, "jittered contiguous timings never rewrite committed text")
    equal(report.junk, [], "no leading fragment survives jittered contiguous timings [\(run.text)]")
    equal(report.missing, [], "no word is lost under jittered contiguous timings [\(run.text)]")
    equal(report.duplicated, [], "no word is duplicated under jittered contiguous timings [\(run.text)]")
}

print("== stabilizer: leading fragment trimming ==")
equal(
    Stabilizer.trimmingLeadingFragment(
        words([("e", 2.70, 2.83), ("no", 2.83, 3.21), ("meu", 3.21, 3.50)]),
        windowStart: 2.70,
        commitTime: 3.70
    ).map(\.text),
    ["no", "meu"],
    "a short leading word inside already committed time is dropped"
)
equal(
    Stabilizer.trimmingLeadingFragment(
        words([("chega", 9.69, 10.95), ("inteira", 10.95, 11.60)]),
        windowStart: 9.69,
        commitTime: 10.69
    ).map(\.text),
    ["chega", "inteira"],
    "a long leading word reaching past the commit frontier is kept"
)
equal(
    Stabilizer.trimmingLeadingFragment(
        words([("o", 1.60, 1.79), ("ditado", 1.79, 2.40)]),
        windowStart: 1.60,
        commitTime: 1.40
    ).map(\.text),
    ["o", "ditado"],
    "a short leading word past the commit frontier is kept"
)
equal(
    Stabilizer.trimmingLeadingFragment(
        words([("este", 0, 0.48), ("teste", 0.48, 1.09)]),
        windowStart: 0,
        commitTime: 0
    ).map(\.text),
    ["este", "teste"],
    "the first window of a recording is never trimmed"
)
equal(
    Stabilizer.trimmingLeadingFragment(
        words([("e", 5.30, 5.40), ("nada", 5.40, 5.90)]),
        windowStart: 4.90,
        commitTime: 6.30
    ).map(\.text),
    ["e", "nada"],
    "a word that does not sit on the window edge is kept"
)
equal(
    Stabilizer.trimmingLeadingFragment([], windowStart: 3.0, commitTime: 4.0).map(\.text),
    [],
    "an empty window trims to nothing"
)
equal(
    Stabilizer.trimmingLeadingFragment(
        words([("e", 2.70, 2.83)]),
        windowStart: 2.70,
        commitTime: 3.70
    ).map(\.text),
    [],
    "a window that is nothing but a fragment trims to nothing"
)

print("== stabilizer: overlap dedup ==")
equal(
    Stabilizer.strippingOverlap(committed: "isso aqui e um teste", tail: "um teste de streaming", maxWords: 10),
    "de streaming",
    "duplicated words at the seam are stripped"
)
equal(
    Stabilizer.strippingOverlap(committed: "bom dia", tail: "Bom, dia! tudo bem", maxWords: 10),
    "tudo bem",
    "dedup ignores case and punctuation"
)
equal(
    Stabilizer.strippingOverlap(committed: "falo português", tail: "portugues fluente", maxWords: 10),
    "fluente",
    "dedup ignores accents"
)
equal(
    Stabilizer.strippingOverlap(committed: "a b c", tail: "x y", maxWords: 10),
    "x y",
    "no overlap leaves the tail intact"
)
equal(
    Stabilizer.strippingOverlap(committed: "um dois tres", tail: "um dois tres", maxWords: 10),
    "",
    "a fully duplicated tail collapses to nothing"
)
equal(
    Stabilizer.strippingOverlap(committed: "ver se a janela", tail: "e a janela deslizante confirma", maxWords: 6),
    "deslizante confirma",
    "a spurious leading fragment before the overlap is skipped"
)
equal(
    Stabilizer.strippingOverlap(committed: "isso e um teste", tail: "ah um teste novo", maxWords: 6),
    "novo",
    "one junk word before a two-word overlap is skipped"
)
equal(
    Stabilizer.strippingOverlap(committed: "nos vamos", tail: "ver se vamos embora", maxWords: 6),
    "ver se vamos embora",
    "a single-word match after skipping is too weak to strip"
)
equal(
    Stabilizer.strippingOverlap(committed: "a b c", tail: "z c y", maxWords: 6),
    "z c y",
    "skipping never strips on a lone one-word match"
)

do {
    var stabilizer = Stabilizer(agreementSteps: 2, margin: 0.7, overlapWords: 10)
    let script = words([("ola", 0, 0.5), ("mundo", 0.5, 1.0)])
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    _ = stabilizer.step(words: script, windowEnd: 3.0)
    let tail = stabilizer.commitFinal("mundo cruel")
    equal(tail, " cruel", "final flush strips what was already committed")
    equal(stabilizer.committedText, "ola mundo cruel", "final flush appends without duplicating")
}

print("== text chunker ==")
equal(TextChunker.sanitize("linha um\nlinha dois"), "linha um linha dois", "newlines collapse to spaces")
check(!TextChunker.sanitize("a\r\n\nb").contains(where: \.isNewline), "no newline survives sanitize")
do {
    let source = "ção ã õ ç não"
    let chunks = TextChunker.chunks(source, limit: 4)
    equal(chunks.joined(), source, "chunks rejoin to the original text")
    check(chunks.allSatisfy { $0.utf16.count <= 4 }, "each chunk respects the utf16 limit")
}
do {
    let emoji = "a👨‍👩‍👧‍👦b"
    let chunks = TextChunker.chunks(emoji, limit: 4)
    equal(chunks.joined(), emoji, "grapheme clusters round-trip")
    check(chunks.contains("👨‍👩‍👧‍👦"), "a multi-scalar grapheme is never split")
    check(chunks.allSatisfy { !$0.isEmpty }, "no empty chunk is produced")
}
do {
    let combining = "a\u{0301}e\u{0302}i\u{0303}"
    let chunks = TextChunker.chunks(combining, limit: 2)
    equal(chunks.joined(), combining, "combining marks stay attached to their base")
}

print("== level meter ==")
do {
    var meter = LevelMeter(attack: 0.65, release: 0.2, floorDecibels: -55, holdSeconds: 0.3)
    meter.ingest(rms: 0.5, peak: 0.6, elapsed: 0.1)
    let attacked = meter.level
    meter.ingest(rms: 0.0, peak: 0.0, elapsed: 0.1)
    let released = meter.level
    check(attacked > 0.3, "attack rises quickly on speech")
    check(released < attacked, "release moves downward")
    check(released > attacked * 0.5, "release is slower than attack")
}
equal(LevelMeter.normalized(0, floorDecibels: -55), 0, "silence maps to zero")
equal(LevelMeter.normalized(1.0, floorDecibels: -55), 1, "full scale maps to one")
check(
    LevelMeter.normalized(0.01, floorDecibels: -55) > 0.2,
    "quiet speech is visible because mapping is in decibels, not linear"
)
do {
    var meter = LevelMeter(attack: 0.65, release: 0.2, floorDecibels: -55, holdSeconds: 0.3)
    for _ in 0..<20 { meter.ingest(rms: 0.0, peak: 0.0, elapsed: 0.1) }
    equal(meter.level, 0, "sustained silence settles on the floor")
    var loud = LevelMeter(attack: 0.65, release: 0.2, floorDecibels: -55, holdSeconds: 0.3)
    loud.ingest(rms: 0.8, peak: 0.9, elapsed: 0.1)
    loud.ingest(rms: 0.0, peak: 0.0, elapsed: 0.05)
    check(loud.peak >= loud.level, "peak hold stays at or above the smoothed level")
}
do {
    let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
    let measured = samples.withUnsafeBufferPointer { buffer in
        LevelMeter.measure(buffer.baseAddress!, count: buffer.count)
    }
    check(abs(measured.rms - 0.5) < 0.001, "rms of a square wave equals its amplitude")
    check(abs(measured.peak - 0.5) < 0.001, "peak tracks the absolute maximum")
}

print("== icon animation: state transitions ==")
let allStates: [IconState] = [
    .idle, .starting, .listening, .recording, .transcribing, .flushing, .success, .error, .cancelled,
]
do {
    var wellFormed = true
    for reduced in [false, true] {
        for state in allStates {
            let plan = IconAnimation.plan(for: state, reduceMotion: reduced)
            if plan.frameCount < 1 { wellFormed = false }
            if plan.isAnimated && plan.interval <= 0 { wellFormed = false }
            if plan.followUp != nil && plan.followUpDelay <= 0 { wellFormed = false }
        }
    }
    check(wellFormed, "every state in both motion modes yields a well-formed plan")
}
check(!IconAnimation.plan(for: .idle, reduceMotion: false).isAnimated, "idle never animates")
equal(IconAnimation.plan(for: .idle, reduceMotion: false).interval, 0, "idle schedules no timer")
check(!IconAnimation.plan(for: .success, reduceMotion: false).isAnimated, "success is a static frame")
check(!IconAnimation.plan(for: .error, reduceMotion: false).isAnimated, "error is a static frame")
check(IconAnimation.plan(for: .transcribing, reduceMotion: false).isAnimated, "transcribing spins")
check(IconAnimation.plan(for: .transcribing, reduceMotion: false).repeats, "the spinner loops")
equal(
    IconAnimation.plan(for: .flushing, reduceMotion: false),
    IconAnimation.plan(for: .transcribing, reduceMotion: false),
    "flushing reuses the transcribing animation"
)
check(IconAnimation.plan(for: .starting, reduceMotion: false).isAnimated, "starting pulses")
check(!IconAnimation.plan(for: .starting, reduceMotion: false).repeats, "the starting pulse is one-shot")
check(IconAnimation.plan(for: .recording, reduceMotion: false).levelDriven, "recording follows real levels")
check(IconAnimation.plan(for: .listening, reduceMotion: false).levelDriven, "listening follows real levels")
check(!IconAnimation.plan(for: .recording, reduceMotion: false).isAnimated, "level-driven states run no timer")
equal(IconAnimation.plan(for: .cancelled, reduceMotion: false).followUp, .idle, "cancel returns to idle")
check(
    IconAnimation.plan(for: .cancelled, reduceMotion: false).render == .blocked,
    "cancel has a frame of its own, distinct from idle"
)

print("== icon animation: reduce motion ==")
do {
    let normal = IconAnimation.plan(for: .transcribing, reduceMotion: false)
    let reduced = IconAnimation.plan(for: .transcribing, reduceMotion: true)
    equal(reduced.frameCount, 2, "reduce motion collapses the spinner to two frames")
    check(reduced.interval >= 1.0, "reduce motion blinks at one hertz or slower")
    check(reduced.interval > normal.interval, "reduce motion slows the spinner down")
}
check(
    !IconAnimation.plan(for: .starting, reduceMotion: true).isAnimated,
    "reduce motion turns the starting pulse into a cut"
)
check(
    IconAnimation.plan(for: .recording, reduceMotion: true).minimumRedrawInterval
        > IconAnimation.plan(for: .recording, reduceMotion: false).minimumRedrawInterval,
    "reduce motion quantizes bar redraws"
)
check(
    IconAnimation.plan(for: .recording, reduceMotion: true).levelDriven,
    "reduce motion still shows level, it only slows the redraw"
)
check(
    !IconAnimation.plan(for: .idle, reduceMotion: true).isAnimated,
    "idle stays static under reduce motion"
)

print("== dictation session ==")

final class FakeSink: TextSink {
    private(set) var emitted: [String] = []
    var shouldFail = false

    func emit(_ text: String) -> Bool {
        if shouldFail { return false }
        emitted.append(text)
        return true
    }

    var joined: String { emitted.joined() }
}

final class FakeGate: FocusGate {
    var available = true
    var secure = false
    var focused = true
    private(set) var anchorCalls = 0
    private(set) var releaseCalls = 0

    var isAvailable: Bool { available }
    var isSecure: Bool { secure }

    func anchor() -> Bool {
        anchorCalls += 1
        return available
    }

    func stillFocused() -> Bool { focused }
    func release() { releaseCalls += 1 }
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 7, sink: sink, gate: gate)
    check(session.begin(), "begin succeeds when accessibility is available and focus anchors")
    equal(gate.anchorCalls, 1, "focus is anchored exactly once at the start")
    _ = session.ingest("ola", generation: 7)
    _ = session.ingest(" mundo", generation: 7)
    let outcome = session.finish(tail: " final", generation: 7)
    equal(outcome, .typed(" final"), "the final flush types the tail")
    equal(sink.joined, "ola mundo final", "everything reaches the input in order")
    equal(session.transcript, "ola mundo final", "transcript matches what was typed")
    equal(session.typedText, session.transcript, "typed text equals the transcript on the happy path")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 1, sink: sink, gate: gate)
    _ = session.begin()
    _ = session.ingest("um", generation: 1)
    _ = session.ingest(" dois", generation: 1)
    gate.focused = false
    let latched = session.ingest(" tres", generation: 1)
    equal(latched, .latched(.focusLost), "losing focus latches injection off")
    equal(sink.joined, "um dois", "nothing is typed after focus is lost")

    gate.focused = true
    let retried = session.ingest(" quatro", generation: 1)
    equal(retried, .latched(.focusLost), "the latch is permanent, regaining focus does not resume")
    equal(sink.joined, "um dois", "still nothing typed after refocus")

    let final = session.finish(tail: " cinco", generation: 1)
    equal(
        final,
        .clipboard(text: "tres quatro cinco", reason: .focusLost),
        "the untyped remainder is offered on the clipboard exactly once"
    )
    equal(sink.joined, "um dois", "the clipboard path never types")
    equal(session.transcript, "um dois tres quatro cinco", "the transcript keeps everything recognized")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 2, sink: sink, gate: gate)
    _ = session.begin()
    _ = session.ingest("segredo", generation: 2)
    gate.secure = true
    let latched = session.ingest(" senha", generation: 2)
    equal(latched, .latched(.secure), "a secure field latches injection off")
    let final = session.finish(tail: "", generation: 2)
    equal(final, .clipboard(text: "senha", reason: .secure), "secure remainder goes to the clipboard")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    gate.available = false
    let session = DictationSession(generation: 3, sink: sink, gate: gate)
    check(!session.begin(), "begin fails when accessibility is unavailable")
    equal(session.latch, .unavailable, "unavailable accessibility latches up front")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 4, sink: sink, gate: gate)
    _ = session.begin()
    sink.shouldFail = true
    let latched = session.ingest("texto", generation: 4)
    equal(latched, .latched(.insertFailed), "a failed insertion latches injection off")
    let final = session.finish(tail: "", generation: 4)
    equal(final, .clipboard(text: "texto", reason: .insertFailed), "failed insertion falls back to clipboard")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 5, sink: sink, gate: gate)
    _ = session.begin()
    _ = session.ingest("um", generation: 5)
    let first = session.finish(tail: " dois", generation: 5)
    equal(first, .typed(" dois"), "the first flush types the tail")
    let second = session.finish(tail: " dois", generation: 5)
    equal(second, .duplicate, "a second flush is refused")
    let third = session.finish(tail: " tres", generation: 5)
    equal(third, .duplicate, "every later flush is refused")
    equal(sink.joined, "um dois", "the tail is typed exactly once")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 6, sink: sink, gate: gate)
    _ = session.begin()
    _ = session.ingest("antes", generation: 6)
    session.cancel()
    equal(session.ingest(" depois", generation: 6), .skipped, "no injection after cancel")
    equal(session.finish(tail: " tarde", generation: 6), .nothing, "no flush after cancel")
    equal(sink.joined, "antes", "cancel prevents all later typing")
    check(!sink.joined.contains("depois"), "text produced after cancel never reaches the input")
    equal(gate.releaseCalls, 1, "cancel releases the focus anchor")
}

do {
    let sink = FakeSink()
    let gate = FakeGate()
    let session = DictationSession(generation: 10, sink: sink, gate: gate)
    _ = session.begin()
    equal(session.ingest("velho", generation: 9), .skipped, "a stale generation is refused")
    equal(session.finish(tail: "velho", generation: 9), .nothing, "a stale flush is refused")
    equal(sink.joined, "", "nothing from a stale generation is typed")
}

equal(DictationSession.remainder(full: "um dois tres", typed: "um dois"), "tres", "remainder drops the typed prefix")
equal(DictationSession.remainder(full: "um dois", typed: ""), "um dois", "remainder is everything when nothing was typed")
equal(DictationSession.remainder(full: "um dois", typed: "um dois"), "", "remainder is empty when all was typed")

print("== meeting archive naming ==")
equal(MeetingArchive.slugify("Reunião do Board"), "reunio-do-board", "slug lowercases, maps spaces, drops accents")
equal(MeetingArchive.slugify("!!!"), "reuniao", "an unusable label falls back to reuniao")
equal(MeetingArchive.slugify(String(repeating: "a", count: 60)).count, 40, "slug caps at 40 chars")
let meetingsRoot = NSTemporaryDirectory() + "harness-meetings-" + UUID().uuidString
let meetingDate = Date(timeIntervalSince1970: 1_790_000_000)
let firstDir = MeetingArchive.directory(root: meetingsRoot, date: meetingDate, label: "reuniao")
check(
    firstDir.lastPathComponent.range(
        of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-reuniao$",
        options: .regularExpression
    ) != nil,
    "directory is stamp-slug [\(firstDir.lastPathComponent)]"
)
try? FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
let secondDir = MeetingArchive.directory(root: meetingsRoot, date: meetingDate, label: "reuniao")
equal(secondDir.lastPathComponent, firstDir.lastPathComponent + "-2", "a colliding minute appends -2")
try? FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
let thirdDir = MeetingArchive.directory(root: meetingsRoot, date: meetingDate, label: "reuniao")
equal(thirdDir.lastPathComponent, firstDir.lastPathComponent + "-3", "the suffix keeps counting")
try? FileManager.default.removeItem(atPath: meetingsRoot)

print("== vault tasks: concatenated json splits on brace depth ==")
let concatenated = """
{
  "title" : "Pagar boleto { com chave }",
  "status" : "pending",
  "priority" : "high",
  "id" : "A",
  "reminders" : [ 1, 2 ],
  "body" : {
    "kind" : "task",
    "due" : "2026-08-20T12:00:00Z"
  }
}{
  "title" : "Tarefa concluída",
  "status" : "completed",
  "id" : "B"
}{
  "title" : "Sem due \\"aspas}\\" dentro",
  "status" : "pending",
  "priority" : "unset",
  "id" : "C",
  "reminders" : [ ]
}
"""
let parsed = VaultTasks.parse(Data(concatenated.utf8))
equal(parsed.count, 3, "three concatenated objects parse")
equal(parsed[0].title, "Pagar boleto { com chave }", "braces inside strings do not break the splitter")
equal(parsed[2].title, "Sem due \"aspas}\" dentro", "escaped quotes and braces survive")
equal(parsed[0].reminders, 2, "reminders count decodes")
check(parsed[0].due != nil, "iso8601 due decodes")
check(parsed[2].due == nil, "a task without due has no date")

print("== vault tasks: open filter and ordering ==")
let openTasks = VaultTasks.open(parsed)
equal(openTasks.count, 2, "completed tasks are dropped")
equal(openTasks[0].id, "A", "a dated task outranks an undated one")
let unsorted = [
    VaultTask(id: "1", title: "b", status: "pending", priority: "unset", due: nil, reminders: 0),
    VaultTask(id: "2", title: "a", status: "pending", priority: "high", due: nil, reminders: 0),
    VaultTask(id: "3", title: "c", status: "pending", priority: "unset", due: Date(timeIntervalSince1970: 2_000_000_000), reminders: 0),
    VaultTask(id: "4", title: "d", status: "pending", priority: "unset", due: Date(timeIntervalSince1970: 1_000_000_000), reminders: 0),
]
equal(VaultTasks.open(unsorted).map(\.id), ["4", "3", "2", "1"], "due asc, then priority, then title")

print("== vault tasks: age labels ==")
let origin = Date(timeIntervalSince1970: 1_000_000)
equal(VaultTasks.age(from: origin, to: origin.addingTimeInterval(30)), "agora", "fresh is agora")
equal(VaultTasks.age(from: origin, to: origin.addingTimeInterval(600)), "há 10 min", "minutes label")
equal(VaultTasks.age(from: origin, to: origin.addingTimeInterval(7200)), "há 2 h", "hours label")
equal(VaultTasks.age(from: origin, to: origin.addingTimeInterval(259_200)), "há 3 d", "days label")

print("== project status: canonical template parses ==")
let canonical = """
# STATUS — brain

> atualizado: 2026-08-17

## Todo
- [ ] endurecer o sandbox da lane pi
- [ ] fechar o pane do herdr

## Feito
- [x] executor omni nativo (2026-08-13)
- [ ] um aberto perdido na seção errada
"""
let brain = ProjectStatusScanner.parse(markdown: canonical, fallbackName: "dir", path: "/x/STATUS.md")
equal(brain.name, "brain", "name comes from the heading")
equal(brain.updated, "2026-08-17", "updated stamp parses")
equal(brain.todos.count, 2, "only unchecked boxes under Todo count")
equal(brain.todos.first, "endurecer o sandbox da lane pi", "todo text is clean")

let offTemplate = ProjectStatusScanner.parse(
    markdown: "# STATUS\n\nprosa livre sem checkbox\n",
    fallbackName: "legado",
    path: "/y/STATUS.md"
)
equal(offTemplate.name, "legado", "a bare heading falls back to the dir name")
equal(offTemplate.todos.count, 0, "free prose yields no todos")
check(offTemplate.updated == nil, "no stamp reads as nil")

print("== project status: scan finds root and depth-1 files ==")
let scanRoot = NSTemporaryDirectory() + "harness-projects-" + UUID().uuidString
func plant(_ relative: String, _ contents: String) {
    let path = scanRoot + "/" + relative
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
}
plant("STATUS.md", "# STATUS — raiz\n\n## Todo\n- [ ] a\n")
plant("alpha/STATUS.md", "# STATUS — alpha\n\n## Todo\n- [ ] b\n- [ ] c\n")
plant("beta/STATUS.md", "# STATUS — beta\n\n## Todo\n\n## Feito\n- [x] tudo (2026-01-01)\n")
plant("gamma/deep/STATUS.md", "# STATUS — fundo\n\n## Todo\n- [ ] d\n")
plant(".hidden/STATUS.md", "# STATUS — oculto\n\n## Todo\n- [ ] e\n")
let scanned = ProjectStatusScanner.scan(roots: [scanRoot])
equal(scanned.map(\.name), ["raiz", "alpha"], "root and depth-1 with todos, nothing hidden or deeper")
equal(scanned[1].todos.count, 2, "todos ride along")
try? FileManager.default.removeItem(atPath: scanRoot)

print("== icon identity: triangle everywhere, colour by situation ==")
equal(IconAnimation.plan(for: .idle, reduceMotion: false).render, IconRender.triangle, "idle is the plain triangle")
equal(IconAnimation.plan(for: .idle, reduceMotion: false).tint, IconTint.neutral, "idle stays monochrome so it adapts to the bar")
equal(IconAnimation.plan(for: .recording, reduceMotion: false).tint, IconTint.live, "capture burns red")
equal(IconAnimation.plan(for: .meeting, reduceMotion: false).tint, IconTint.live, "a meeting burns red too")
equal(IconAnimation.plan(for: .transcribing, reduceMotion: false).tint, IconTint.work, "transcription is amber")
equal(IconAnimation.plan(for: .success, reduceMotion: false).tint, IconTint.good, "success is green")
for calmState in [IconState.idle, .transcribing, .flushing, .success, .error] {
    let render = IconAnimation.plan(for: calmState, reduceMotion: false).render
    check(render != .symbol("mic") && render != .symbol("mic.fill"), "no mic glyph outside capture for \(calmState)")
}
equal(IconAnimation.plan(for: .recording, reduceMotion: false).render, IconRender.triangleLevel, "dictation drives the triangle with the level")
check(IconAnimation.plan(for: .meeting, reduceMotion: false).repeats, "the meeting triangle beats forever")
check(!IconAnimation.plan(for: .meeting, reduceMotion: true).isAnimated, "Reduce Motion stills the beat")

print("== icon: level and beat scaling ==")
check(IconAnimation.triangleScale(level: 0, peak: 0) < IconAnimation.triangleScale(level: 1, peak: 1), "louder means bigger")
check(IconAnimation.triangleScale(level: 5, peak: 5) <= 1, "scale never exceeds the icon box")
check(IconAnimation.triangleScale(level: -3, peak: -3) > 0.5, "silence still draws a visible triangle")
let beats = (0..<24).map { IconAnimation.beatScale(frame: $0, frameCount: 24) }
check(beats.allSatisfy { $0 >= 0.8 && $0 <= 1.01 }, "the beat stays inside a calm range")
check(beats.max()! - beats.min()! > 0.1, "the beat is actually visible")

print("== hub actions: one button per verb, icon follows state ==")
let calmActions = HubModel.actionSpecs(dictating: false, meeting: false, call: false, awake: false)
equal(calmActions.map(\.action), [.dictate, .meeting, .call, .insomnia, .notes, .refresh], "the button row is the six verbs, in order")
check(calmActions.allSatisfy { !$0.on }, "nothing is lit when nothing is running")
check(calmActions.allSatisfy { !$0.tooltip.isEmpty }, "every button says what it does")
check(Set(calmActions.map(\.symbol)).count == calmActions.count, "no two buttons share a glyph")
let busyActions = HubModel.actionSpecs(dictating: true, meeting: true, call: true, awake: true)
equal(busyActions[0].symbol, "mic.fill", "dictation fills its mic while live")
equal(busyActions[1].symbol, "stop.fill", "a running meeting offers stop")
equal(busyActions[2].symbol, "phone.down.fill", "a running call offers hang up")
equal(busyActions[3].symbol, "cup.and.saucer.fill", "staying awake fills the cup")
check(busyActions.prefix(4).allSatisfy(\.on), "live verbs light up")
check(busyActions.map(\.tooltip) != calmActions.map(\.tooltip), "tooltips flip with the state")

print("== status.md write-back ==")
let board = """
# STATUS — demo

> atualizado: 2026-08-18

## Todo
- [ ] primeira coisa
- [ ] segunda coisa

## Feito
- [x] coisa antiga (2026-01-01)
"""
let marked = StatusTodoWriter.complete(markdown: board, todo: "primeira coisa", on: "2026-08-18")
check(marked != nil, "a known todo is found")
check(!marked!.contains("- [ ] primeira coisa"), "the todo leaves the Todo section")
check(marked!.contains("- [x] primeira coisa (2026-08-18)"), "it lands in Feito with the date")
check(marked!.contains("- [ ] segunda coisa"), "the other todos survive untouched")
check(marked!.contains("> atualizado: 2026-08-18"), "the rest of the file is preserved")
let doneIndex = marked!.range(of: "## Feito")!.lowerBound
let entryIndex = marked!.range(of: "- [x] primeira coisa")!.lowerBound
check(doneIndex < entryIndex, "the entry goes under the Feito heading")
check(StatusTodoWriter.complete(markdown: board, todo: "nao existe", on: "2026-08-18") == nil, "an unknown todo changes nothing")
check(
    StatusTodoWriter.complete(markdown: board, todo: "coisa antiga", on: "2026-08-18") == nil,
    "already-done lines are never re-marked"
)
let noSection = StatusTodoWriter.complete(
    markdown: "# STATUS — x\n\n## Todo\n- [ ] só isso\n",
    todo: "só isso",
    on: "2026-08-18"
)
check(noSection!.contains("## Feito"), "a missing Feito section is created")

print("== status.md write-back touches the real file atomically ==")
let boardPath = NSTemporaryDirectory() + "harness-status-" + UUID().uuidString + ".md"
FileManager.default.createFile(atPath: boardPath, contents: Data(board.utf8))
check(StatusTodoWriter.complete(path: boardPath, todo: "segunda coisa"), "the write reports success")
let reread = try! String(contentsOfFile: boardPath, encoding: .utf8)
check(reread.contains("- [x] segunda coisa ("), "the file on disk carries the completion")
check(reread.contains("- [ ] primeira coisa"), "the untouched todo is still there")
check(!FileManager.default.fileExists(atPath: boardPath + ".garime-tmp"), "no temp file is left behind")
check(!StatusTodoWriter.complete(path: "/nonexistent/STATUS.md", todo: "x"), "a missing file fails quietly")
try? FileManager.default.removeItem(atPath: boardPath)

print("== hub panel model ==")
equal(HubModel.truncate("curta", limit: 58), "curta", "short titles pass through")
let long = "revisar o contrato da ponte com o time de infra antes do deploy de sexta"
let cut = HubModel.truncate(long, limit: 40)
check(cut.hasSuffix("…"), "long titles gain an ellipsis")
check(cut.count <= 42, "truncation respects the limit")
check(!cut.contains("  "), "truncation cuts on a word boundary")

let panelTasks = (1...5).map {
    VaultTask(id: "\($0)", title: "tarefa \($0)", status: "pending", priority: "unset", due: nil, reminders: 0)
}
let todosProject = ProjectStatus(
    name: "demo",
    updated: "2026-08-18",
    todos: ["alfa", "beta"],
    path: "/demo/STATUS.md"
)
let todos = HubModel.todosSection(todosProject, titleLimit: 58)
equal(todos.rows.count, 2, "every todo of the project shows up")
check(todos.rows.allSatisfy(\.checkable), "project todos can be checked off")
equal(todos.rows.first?.id, "todo:alfa", "the row id carries the exact todo text")
equal(HubModel.projectsSection([todosProject], limit: 5, titleLimit: 58).rows.first?.id, "project:/demo/STATUS.md", "project rows address the file")
check(HubModel.projectsSection([todosProject], limit: 5, titleLimit: 58).rows.first!.chevron, "projects are navigable")
check(!HubModel.tasksSection(panelTasks, limit: 3, titleLimit: 58).rows.contains { $0.checkable }, "vault tasks stay read-only in the panel")

let taskSection = HubModel.tasksSection(panelTasks, limit: 3, titleLimit: 58)
equal(taskSection.strong, "5 tarefas", "the header carries the full count")
equal(taskSection.rows.count, 4, "three rows plus the overflow line")
equal(taskSection.rows.last?.title, "e mais 2", "overflow names how many are hidden")
equal(taskSection.rows.first?.symbol, "circle", "tasks use the open circle glyph")
equal(HubModel.tasksSection([], limit: 3, titleLimit: 58).strong, "nenhuma tarefa", "empty state reads naturally")
equal(
    HubModel.tasksSection([panelTasks[0]], limit: 3, titleLimit: 58).post,
    " aberta",
    "singular agrees with the count"
)

let panelProjects = [
    ProjectStatus(name: "pequeno", updated: nil, todos: ["a"], path: "/p"),
    ProjectStatus(name: "grande", updated: nil, todos: ["a", "b", "c"], path: "/g"),
]
let projectSection = HubModel.projectsSection(panelProjects, limit: 5, titleLimit: 58)
equal(projectSection.rows.first?.title, "grande", "projects sort by pending count")
equal(projectSection.rows.first?.trailing, "3", "the trailing badge is the todo count")

let header = HubModel.dateHeader(
    Date(timeIntervalSince1970: 1_755_500_000),
    locale: Locale(identifier: "pt_BR")
)
check(header.0.first?.isUppercase == true, "the weekday is capitalised")
check(header.1.contains("de"), "the date reads in full portuguese")

print("== rec.state probe ==")
let liveState = RecProbe.parse("/Users/x/Recordings/2026-08-18-1010-reuniao\n123\n\n") { _ in true }
check(liveState == RecState(
    directory: "/Users/x/Recordings/2026-08-18-1010-reuniao",
    pid: 123,
    active: true
), "a live pid reads as an active recording")
let deadState = RecProbe.parse("/Users/x/Recordings/dir\n123\nSpeakers\n") { _ in false }
equal(deadState?.active, false, "a dead pid reads as inactive")
check(RecProbe.parse("\n123\n") { _ in true } == nil, "an empty directory line is rejected")
check(RecProbe.parse("/tmp/dir\nabc\n") { _ in true } == nil, "a non-numeric pid is rejected")
check(RecProbe.parse("/tmp/dir") { _ in true } == nil, "a truncated state file is rejected")
check(RecProbe.read(path: "/nonexistent/rec.state") == nil, "a missing state file reads as nil")

print("== capture probe reads the daemon status files ==")
let captureRoot = NSTemporaryDirectory() + "harness-capture-" + UUID().uuidString
let captureNow = Date()
func touch(_ relative: String, at date: Date, contents: String = "") {
    let path = captureRoot + "/" + relative
    try? FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

equal(CaptureProbe.read(root: captureRoot).exists, false, "a missing install reads as absent")
equal(
    CaptureProbe.condition(CaptureProbe.read(root: captureRoot), now: captureNow),
    .absent,
    "absent install raises no alarm"
)
check(CaptureProbe.line(for: .absent) == nil, "absent renders no menu line")

touch("status/capture.heartbeat", at: captureNow.addingTimeInterval(-30))
var captureSnap = CaptureProbe.read(root: captureRoot)
equal(captureSnap.exists, true, "a status dir makes the install visible")
equal(CaptureProbe.condition(captureSnap, now: captureNow), .healthy, "a fresh heartbeat is healthy")
check(CaptureProbe.line(for: .healthy) == nil, "healthy renders no menu line")

touch("status/capture.heartbeat", at: captureNow.addingTimeInterval(-900))
captureSnap = CaptureProbe.read(root: captureRoot)
guard case .silent(let silentAge) = CaptureProbe.condition(captureSnap, now: captureNow) else {
    check(false, "a stale heartbeat reads as silent")
    exit(1)
}
check(abs(silentAge - 900) < 5, "silent carries the heartbeat age [\(Int(silentAge))s]")
check(
    CaptureProbe.line(for: .silent(900)) == "Prints: daemon parado há 15 min",
    "silent renders the age in minutes"
)

touch("status/stranded", at: captureNow, contents: "a.png\n\nb.png\n")
captureSnap = CaptureProbe.read(root: captureRoot)
equal(captureSnap.strandedCount, 2, "blank lines in stranded are ignored")
equal(
    CaptureProbe.condition(captureSnap, now: captureNow),
    .stranded(2),
    "stranded outranks the heartbeat"
)
check(CaptureProbe.line(for: .stranded(1)) == "Prints: 1 preso", "singular stranded line")
check(CaptureProbe.line(for: .stranded(2)) == "Prints: 2 presos", "plural stranded line")

print("== capture watcher flashes on processed prints ==")
touch("status/stranded", at: captureNow, contents: "")
touch("status/capture.heartbeat", at: captureNow)
touch("registry/processed.json", at: captureNow.addingTimeInterval(-60), contents: "{}")
let watcher = CaptureWatcher(root: captureRoot)
var flashes = 0
var conditions: [CaptureCondition] = []
watcher.onProcessed = { flashes += 1 }
watcher.onCondition = { conditions.append($0) }
watcher.poll(now: captureNow)
equal(flashes, 0, "the first poll never flashes")
equal(conditions.last, .healthy, "the first poll reports the condition")
watcher.poll(now: captureNow)
equal(flashes, 0, "an unchanged registry does not flash")
touch("registry/processed.json", at: captureNow.addingTimeInterval(60), contents: "{}")
watcher.poll(now: captureNow)
equal(flashes, 1, "a new processed stamp flashes once")
watcher.poll(now: captureNow)
equal(flashes, 1, "the flash does not repeat without a new stamp")
try? FileManager.default.removeItem(atPath: captureRoot)

func ownSleepAssertions() -> Int {
    var raw: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
          let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else { return -1 }
    let mine = dict[NSNumber(value: getpid())] ?? []
    return mine.filter { ($0["AssertType"] as? String) == kIOPMAssertionTypePreventSystemSleep }.count
}

print("== insomnia controller holds a real power assertion ==")
let insomnia = InsomniaController()
equal(ownSleepAssertions(), 0, "no sleep assertion before activation")
check(insomnia.toggle(), "toggle reports active")
check(insomnia.isActive, "controller tracks the active state")
equal(ownSleepAssertions(), 1, "exactly one PreventSystemSleep assertion is held")
insomnia.activate()
equal(ownSleepAssertions(), 1, "a second activate does not stack assertions")
check(!insomnia.toggle(), "toggle reports inactive")
check(!insomnia.isActive, "controller tracks the inactive state")
equal(ownSleepAssertions(), 0, "the assertion is released on deactivate")
insomnia.deactivate()
equal(ownSleepAssertions(), 0, "a second deactivate is a no-op")
do {
    let scoped = InsomniaController()
    scoped.activate()
    equal(ownSleepAssertions(), 1, "a scoped controller holds its assertion")
}
equal(ownSleepAssertions(), 0, "deinit releases a forgotten assertion")

print("")
print("units passed: \(passes)   failed: \(failures)")
exit(failures == 0 ? 0 : 1)
