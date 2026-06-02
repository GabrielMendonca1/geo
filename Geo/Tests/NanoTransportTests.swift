import XCTest
@testable import Geo

actor MockNanoTransport: NanoTransport {
    var runTurnCalls: [(channelID: String, text: String, attachmentCount: Int)] = []
    var cancelCalls: [String] = []
    var resetCalls: [String] = []
    var historyCalls: [(channelID: String, limit: Int, after: Int64?)] = []
    var listCalls: [String?] = []
    var nextEvents: [TurnEvent] = []

    func setNextEvents(_ events: [TurnEvent]) { self.nextEvents = events }

    func runTurn(
        channelID: String,
        text: String,
        attachments: [NanoTransportAttachment]
    ) async throws -> AsyncThrowingStream<TurnEvent, Error> {
        runTurnCalls.append((channelID, text, attachments.count))
        let events = nextEvents
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish()
        }
    }

    func cancel(channelID: String) async throws {
        cancelCalls.append(channelID)
    }

    func resetSession(channelID: String) async throws {
        resetCalls.append(channelID)
    }

    func getHistory(channelID: String, limit: Int, afterCursor: Int64?) async throws -> [NanoHistoryMessage] {
        historyCalls.append((channelID, limit, afterCursor))
        return []
    }

    func listChannels(prefix: String?) async throws -> [NanoChannelInfo] {
        listCalls.append(prefix)
        return []
    }
}

final class NanoTransportTests: XCTestCase {

    func testProtocolSatisfiedByHermesTransport() {
        let url = URL(string: "http://127.0.0.1:8642")!
        let t: any NanoTransport = HermesHTTPTransport(baseURL: url, apiKey: "test")
        _ = t
    }

    func testMockTransportRecordsCalls() async throws {
        let mock = MockNanoTransport()
        await mock.setNextEvents([.text(delta: "hi"), .done(reply: nil)])
        let stream = try await mock.runTurn(channelID: "main", text: "hello", attachments: [])
        var collected: [TurnEvent] = []
        for try await event in stream { collected.append(event) }
        XCTAssertEqual(collected.count, 2)
        let runs = await mock.runTurnCalls
        XCTAssertEqual(runs.first?.channelID, "main")
        XCTAssertEqual(runs.first?.text, "hello")

        try await mock.cancel(channelID: "main")
        try await mock.resetSession(channelID: "main")
        _ = try await mock.getHistory(channelID: "main", limit: 50, afterCursor: nil)
        _ = try await mock.listChannels(prefix: "nano:")

        let cancels = await mock.cancelCalls
        let resets = await mock.resetCalls
        let hist = await mock.historyCalls
        let lists = await mock.listCalls
        XCTAssertEqual(cancels, ["main"])
        XCTAssertEqual(resets, ["main"])
        XCTAssertEqual(hist.first?.channelID, "main")
        XCTAssertEqual(lists.first, "nano:")
    }

    func testSSEParserEventNameLine() {
        XCTAssertEqual(SSELineParser.parse("event: text"), .eventName("text"))
        XCTAssertEqual(SSELineParser.parse("event:done"), .eventName("done"))
    }

    func testSSEParserDataLine() {
        XCTAssertEqual(SSELineParser.parse("data: {\"a\":1}"), .dataLine("{\"a\":1}"))
        XCTAssertEqual(SSELineParser.parse("data:{\"a\":1}"), .dataLine("{\"a\":1}"))
    }

    func testSSEParserBlankLineDispatches() {
        XCTAssertEqual(SSELineParser.parse(""), .dispatch)
    }

    func testSSEParserCommentLineIgnored() {
        XCTAssertEqual(SSELineParser.parse(": ping"), .comment)
    }

    func testEventMapperTextDelta() {
        let frame = SSEFrame(event: "text", data: "{\"delta\":\"hello\"}")
        guard case .text(let d) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(d, "hello")
    }

    func testEventMapperToolUse() {
        let frame = SSEFrame(event: "tool_use", data: "{\"id\":\"t1\",\"name\":\"foo\",\"input\":{\"x\":1}}")
        guard case .toolUse(let id, let name, _) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .toolUse")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(name, "foo")
    }

    func testEventMapperToolResult() {
        let frame = SSEFrame(event: "tool_result", data: "{\"tool_use_id\":\"t1\",\"content\":[1,2,3],\"is_error\":false}")
        guard case .toolResult(let id, _, let isErr) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .toolResult")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertFalse(isErr)
    }

    func testEventMapperToolPartial() {
        let frame = SSEFrame(event: "tool_partial", data: "{\"tool_use_id\":\"t1\",\"partial\":{\"tail\":[\"a\"]}}")
        guard case .toolPartial(let id, _) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .toolPartial")
        }
        XCTAssertEqual(id, "t1")
    }

    func testEventMapperAgentDispatch() {
        let frame = SSEFrame(event: "agent_dispatch", data: "{\"workspace_id\":\"ws1\",\"status\":\"running\",\"last_line\":\"step\"}")
        guard case .agentDispatch(let ws, let st, let ll) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .agentDispatch")
        }
        XCTAssertEqual(ws, "ws1")
        XCTAssertEqual(st, "running")
        XCTAssertEqual(ll, "step")
    }

    func testEventMapperDone() {
        let frame = SSEFrame(event: "done", data: "{\"reply\":\"bye\"}")
        guard case .done(let reply) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .done")
        }
        XCTAssertEqual(reply, "bye")
    }

    func testEventMapperFailure() {
        let frame = SSEFrame(event: "error", data: "{\"message\":\"oops\"}")
        guard case .failure(let msg) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .failure")
        }
        XCTAssertEqual(msg, "oops")
    }

    func testEventMapperFallsBackToEventInDataPayload() {
        let frame = SSEFrame(event: nil, data: "{\"event\":\"text\",\"delta\":\"x\"}")
        guard case .text(let d) = HermesEventMapper.map(frame: frame) else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(d, "x")
    }

    func testHermesRunTurnTwiceCancelsFirstRun() async throws {
        final class CallCount: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func bumpAndGet() -> Int {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let calls = CallCount()

        class StubProtocolWithDynamicBody: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var calls: CallCount = CallCount()
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else {
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path == "/v1/runs" && request.httpMethod == "POST" {
                    let n = Self.calls.bumpAndGet()
                    let body = "{\"id\":\"run-\(n)\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasPrefix("/v1/runs/") && url.path.hasSuffix("/events") {
                    let runID = url.deletingLastPathComponent().lastPathComponent
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let client = self.client
                    let proto = self
                    Task.detached {
                        for i in 0..<50 {
                            if Task.isCancelled { break }
                            let chunk = "event: text\ndata: {\"delta\":\"\(runID)-\(i)\"}\n\n".data(using: .utf8)!
                            client?.urlProtocol(proto, didLoad: chunk)
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                if url.path.hasSuffix("/stop") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data())
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        StubProtocolWithDynamicBody.calls = calls

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocolWithDynamicBody.self]
        let stubSession = URLSession(configuration: config)

        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: stubSession)
        let stream1 = try await transport.runTurn(channelID: "c1", text: "first", attachments: [])

        let firstSawAtLeastOne = expectation(description: "first stream emitted")
        let firstStreamDone = expectation(description: "first stream finished")
        var firstEvents: [TurnEvent] = []
        let firstTask = Task {
            do {
                for try await ev in stream1 {
                    firstEvents.append(ev)
                    if firstEvents.count == 1 { firstSawAtLeastOne.fulfill() }
                }
            } catch {}
            firstStreamDone.fulfill()
        }

        await fulfillment(of: [firstSawAtLeastOne], timeout: 3.0)

        let stream2 = try await transport.runTurn(channelID: "c1", text: "second", attachments: [])

        await fulfillment(of: [firstStreamDone], timeout: 3.0)

        var secondEvents: [TurnEvent] = []
        let secondTask = Task {
            do {
                var collected = 0
                for try await ev in stream2 {
                    secondEvents.append(ev)
                    collected += 1
                    if collected >= 2 { break }
                }
            } catch {}
        }

        _ = await secondTask.value
        firstTask.cancel()
        _ = await firstTask.value

        XCTAssertTrue(secondEvents.allSatisfy { event in
            if case .text(let d) = event { return d.hasPrefix("run-2") }
            return false
        }, "second stream events should belong to run-2, got \(secondEvents)")
    }

    func testHermesCancelEndsStream() async throws {
        final class CallBox: @unchecked Sendable {
            let lock = NSLock()
            var stopHit = false
            func setStopHit() { lock.lock(); stopHit = true; lock.unlock() }
            func getStopHit() -> Bool { lock.lock(); defer { lock.unlock() }; return stopHit }
        }
        let box = CallBox()

        class StubProto: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var box: CallBox = CallBox()
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
                if url.path == "/v1/runs" && request.httpMethod == "POST" {
                    let body = "{\"id\":\"run-x\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/stop") {
                    Self.box.setStopHit()
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data())
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/events") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let client = self.client
                    let proto = self
                    Task.detached {
                        for i in 0..<1000 {
                            if Task.isCancelled { break }
                            let chunk = "event: text\ndata: {\"delta\":\"t\(i)\"}\n\n".data(using: .utf8)!
                            client?.urlProtocol(proto, didLoad: chunk)
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        StubProto.box = box

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProto.self]
        let session = URLSession(configuration: config)
        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: session)
        let stream = try await transport.runTurn(channelID: "c1", text: "hi", attachments: [])

        let sawFirst = expectation(description: "saw first event")
        let streamEnded = expectation(description: "stream ended")
        var events: [TurnEvent] = []
        let task = Task {
            do {
                for try await ev in stream {
                    events.append(ev)
                    if events.count == 1 { sawFirst.fulfill() }
                }
            } catch {}
            streamEnded.fulfill()
        }
        await fulfillment(of: [sawFirst], timeout: 3.0)
        try await transport.cancel(channelID: "c1")
        await fulfillment(of: [streamEnded], timeout: 3.0)
        XCTAssertTrue(box.getStopHit(), "cancel() should POST /v1/runs/run-x/stop")
        _ = await task.value
    }

    func testHermesCancelOnlyHitsStopEndpoint() async throws {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var paths: [String] = []
            func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
            func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
        }
        let log = Log()

        class StubProto: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var log: Log = Log()
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
                Self.log.add(url.path)
                if url.path == "/v1/runs" {
                    let body = "{\"id\":\"run-z\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/events") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let proto = self
                    let client = self.client
                    Task.detached {
                        for i in 0..<1000 {
                            if Task.isCancelled { break }
                            let chunk = "event: text\ndata: {\"delta\":\"x\(i)\"}\n\n".data(using: .utf8)!
                            client?.urlProtocol(proto, didLoad: chunk)
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        StubProto.log = log

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProto.self]
        let session = URLSession(configuration: config)
        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: session)
        let stream = try await transport.runTurn(channelID: "c1", text: "hi", attachments: [])

        let sawFirst = expectation(description: "first event")
        var events: [TurnEvent] = []
        let task = Task {
            do {
                for try await ev in stream {
                    events.append(ev)
                    if events.count == 1 { sawFirst.fulfill() }
                }
            } catch {}
        }
        await fulfillment(of: [sawFirst], timeout: 3.0)
        try await transport.cancel(channelID: "c1")
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        _ = await task.value

        let paths = log.snapshot()
        XCTAssertTrue(paths.contains("/v1/runs/run-z/stop"), "expected /v1/runs/run-z/stop in \(paths)")
        XCTAssertFalse(paths.contains("/v1/runs/cancel"), "should not call /v1/runs/cancel (defensive duplicate removed)")
    }

    func testHermesSSEHandlesMidStreamGap() async throws {
        class StubProto: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
                if url.path == "/v1/runs" {
                    let body = "{\"id\":\"run-gap\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/events") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let client = self.client
                    let proto = self
                    Task.detached {
                        let first = "event: text\ndata: {\"delta\":\"a\"}\n\n".data(using: .utf8)!
                        client?.urlProtocol(proto, didLoad: first)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        let keepAlive = ": keepalive\n\n".data(using: .utf8)!
                        client?.urlProtocol(proto, didLoad: keepAlive)
                        let second = "event: text\ndata: {\"delta\":\"b\"}\n\n".data(using: .utf8)!
                        client?.urlProtocol(proto, didLoad: second)
                        let done = "event: done\ndata: {\"reply\":\"ab\"}\n\n".data(using: .utf8)!
                        client?.urlProtocol(proto, didLoad: done)
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProto.self]
        let session = URLSession(configuration: config)
        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: session)
        let stream = try await transport.runTurn(channelID: "gap", text: "hi", attachments: [])
        var deltas: [String] = []
        var reply: String?
        for try await ev in stream {
            switch ev {
            case .text(let d): deltas.append(d)
            case .done(let r): reply = r ?? ""
            default: break
            }
        }
        XCTAssertEqual(deltas, ["a", "b"])
        XCTAssertEqual(reply, "ab")
    }

    func testHermesPerChannelStreamsAreIndependent() async throws {
        class StubProto: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var runCounter = NSLock()
            nonisolated(unsafe) static var n = 0
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
                if url.path == "/v1/runs" && request.httpMethod == "POST" {
                    Self.runCounter.lock()
                    Self.n += 1
                    let id = "run-\(Self.n)"
                    Self.runCounter.unlock()
                    let body = "{\"id\":\"\(id)\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/events") {
                    let runID = url.deletingLastPathComponent().lastPathComponent
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let client = self.client
                    let proto = self
                    Task.detached {
                        for i in 0..<3 {
                            let chunk = "event: text\ndata: {\"delta\":\"\(runID)-\(i)\"}\n\n".data(using: .utf8)!
                            client?.urlProtocol(proto, didLoad: chunk)
                            try? await Task.sleep(nanoseconds: 30_000_000)
                        }
                        let done = "event: done\ndata: {\"reply\":\"\(runID)\"}\n\n".data(using: .utf8)!
                        client?.urlProtocol(proto, didLoad: done)
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        StubProto.runCounter.lock(); StubProto.n = 0; StubProto.runCounter.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProto.self]
        let session = URLSession(configuration: config)
        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: session)

        let streamA = try await transport.runTurn(channelID: "A", text: "hi", attachments: [])
        let streamB = try await transport.runTurn(channelID: "B", text: "hi", attachments: [])

        async let aEvents: [String] = {
            var deltas: [String] = []
            do {
                for try await ev in streamA {
                    if case .text(let d) = ev { deltas.append(d) }
                }
            } catch {}
            return deltas
        }()
        async let bEvents: [String] = {
            var deltas: [String] = []
            do {
                for try await ev in streamB {
                    if case .text(let d) = ev { deltas.append(d) }
                }
            } catch {}
            return deltas
        }()

        let (a, b) = await (aEvents, bEvents)

        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(b.count, 3)
        XCTAssertTrue(a.allSatisfy { !b.contains($0) }, "A and B streams should not share events: A=\(a), B=\(b)")
        XCTAssertTrue(a.allSatisfy { $0.hasPrefix("run-") })
        XCTAssertTrue(b.allSatisfy { $0.hasPrefix("run-") })
        let aRunID = a.first?.split(separator: "-").prefix(2).joined(separator: "-")
        let bRunID = b.first?.split(separator: "-").prefix(2).joined(separator: "-")
        XCTAssertNotNil(aRunID)
        XCTAssertNotNil(bRunID)
        XCTAssertNotEqual(aRunID, bRunID, "Each channel should get a distinct run id")
    }

    func testHermesCancelImmediatelyStopsDataTask() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var stopHits: Int = 0
            var startHits: Int = 0
            func hitStop() { lock.lock(); stopHits += 1; lock.unlock() }
            func hitStart() { lock.lock(); startHits += 1; lock.unlock() }
            func snapshot() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (startHits, stopHits) }
        }
        let box = Box()

        class StubProto: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var box: Box = Box()
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
                if url.path == "/v1/runs" && request.httpMethod == "POST" {
                    let body = "{\"id\":\"run-hard\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/events") {
                    Self.box.hitStart()
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let client = self.client
                    let proto = self
                    Task.detached {
                        for i in 0..<10_000 {
                            let chunk = "event: text\ndata: {\"delta\":\"t\(i)\"}\n\n".data(using: .utf8)!
                            client?.urlProtocol(proto, didLoad: chunk)
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                if url.path.hasSuffix("/stop") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data())
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {
                if let url = request.url, url.path.hasSuffix("/events") {
                    Self.box.hitStop()
                }
            }
        }
        StubProto.box = box

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProto.self]
        let session = URLSession(configuration: config)
        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: session)
        let stream = try await transport.runTurn(channelID: "hard", text: "go", attachments: [])

        let sawFirst = expectation(description: "first event")
        let streamEnded = expectation(description: "stream ended")
        var events: [TurnEvent] = []
        let task = Task {
            do {
                for try await ev in stream {
                    events.append(ev)
                    if events.count == 1 { sawFirst.fulfill() }
                }
            } catch {}
            streamEnded.fulfill()
        }
        await fulfillment(of: [sawFirst], timeout: 3.0)

        try await transport.cancel(channelID: "hard")

        await fulfillment(of: [streamEnded], timeout: 1.0)

        var stops = 0
        for _ in 0..<40 {
            stops = box.snapshot().1
            if stops > 0 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(box.snapshot().0, 0, "events endpoint must have been opened")
        XCTAssertGreaterThan(stops, 0, "URLProtocol.stopLoading() should be invoked after dataTask.cancel() runs")
        _ = await task.value
    }

    func testHermesCancelPropagatesEvenWhenServerSilent() async throws {
        class StubProto: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
                if url.path == "/v1/runs" && request.httpMethod == "POST" {
                    let body = "{\"id\":\"run-silent\"}".data(using: .utf8)!
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: body)
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                if url.path.hasSuffix("/events") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    let client = self.client
                    let proto = self
                    Task.detached {
                        let first = "event: text\ndata: {\"delta\":\"hi\"}\n\n".data(using: .utf8)!
                        client?.urlProtocol(proto, didLoad: first)
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        client?.urlProtocolDidFinishLoading(proto)
                    }
                    return
                }
                if url.path.hasSuffix("/stop") {
                    let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                    client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: Data())
                    client?.urlProtocolDidFinishLoading(self)
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProto.self]
        let session = URLSession(configuration: config)
        let transport = HermesHTTPTransport(baseURL: URL(string: "http://stub.test")!, apiKey: "k", session: session)
        let stream = try await transport.runTurn(channelID: "silent", text: "go", attachments: [])

        let sawFirst = expectation(description: "first event")
        let streamEnded = expectation(description: "stream ended")
        let task = Task {
            do {
                var count = 0
                for try await _ in stream {
                    count += 1
                    if count == 1 { sawFirst.fulfill() }
                }
            } catch {}
            streamEnded.fulfill()
        }
        await fulfillment(of: [sawFirst], timeout: 3.0)

        let cancelStart = Date()
        try await transport.cancel(channelID: "silent")
        await fulfillment(of: [streamEnded], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(cancelStart)
        XCTAssertLessThan(elapsed, 0.5, "cancel must propagate within 500ms even when server is silent, got \(elapsed)s")
        _ = await task.value
    }

    func testHermesEnvLoadsKeyValues() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-env-\(UUID().uuidString).env")
        let body = """
        # comment
        API_SERVER_KEY="abc123"
        API_SERVER_ENABLED=true
        """
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = HermesEnv(envPath: tmp.path)
        XCTAssertEqual(env.apiServerKey, "abc123")
        XCTAssertTrue(env.apiServerEnabled)
    }
}
