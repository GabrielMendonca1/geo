import XCTest
import GeoCore
@testable import Garime

final class BridgeTasksDecodingTests: XCTestCase {
    private func decode(_ json: String) throws -> BridgeTasksRepository.DecodedTasks {
        try BridgeTasksRepository.decodeTasks(from: Data(json.utf8))
    }

    private let canonical = """
    {"id":"a1","title":"fixture canonica","status":"completed","priority":"high","tagIds":[],
     "orderIndex":0,"createdAt":"2026-01-02T10:00:00Z","modifiedAt":"2026-01-02T11:00:00Z",
     "externalEKEventID":null,"reminders":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","trigger":{"kind":"offset","offset":"At time"},"fired":true}],
     "body":{"kind":"task","due":"2026-01-03T23:59:00Z"}}
    """

    func testCanonicalTaskDecodes() throws {
        let result = try decode("[\(canonical)]")
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].kind, .task)
        XCTAssertEqual(result.tasks[0].priority, .high)
        XCTAssertEqual(result.tasks[0].reminders.count, 1)
    }

    func testUnknownBodyKindBecomesGenericTask() throws {
        let json = """
        [{"id":"b1","title":"kind novo","createdAt":"2026-01-02T10:00:00Z",
          "body":{"kind":"note","due":"2026-01-05T12:00:00Z"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks[0].kind, .task)
        XCTAssertEqual(result.tasks[0].anchorDate, ISO8601DateFormatter().date(from: "2026-01-05T12:00:00Z"))
    }

    func testTaskBodyWithoutAnchorFallsBackToCreatedAt() throws {
        let json = """
        [{"id":"b2","title":"sem due","createdAt":"2026-01-02T10:00:00Z","body":{"kind":"task"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks[0].anchorDate, ISO8601DateFormatter().date(from: "2026-01-02T10:00:00Z"))
    }

    func testEventWithoutEndKeepsStart() throws {
        let json = """
        [{"id":"b3","title":"evento truncado","createdAt":"2026-01-02T10:00:00Z",
          "body":{"kind":"event","start":"2026-01-09T14:00:00Z"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks[0].kind, .event)
        XCTAssertEqual(result.tasks[0].endTime, ISO8601DateFormatter().date(from: "2026-01-09T14:00:00Z"))
    }

    func testMissingBodyKeepsTask() throws {
        let json = """
        [{"id":"b4","title":"sem body","createdAt":"2026-01-02T10:00:00Z"}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks[0].kind, .task)
    }

    func testUnparseableAnchorFallsBackInsteadOfDropping() throws {
        let json = """
        [{"id":"b5","title":"due humano","createdAt":"2026-01-02T10:00:00Z",
          "body":{"kind":"task","due":"amanha"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks[0].anchorDate, ISO8601DateFormatter().date(from: "2026-01-02T10:00:00Z"))
    }

    func testFractionalAndDateOnlyAnchorsParse() throws {
        let json = """
        [{"id":"c1","title":"fracionado","createdAt":"2026-01-02T10:00:00.123Z",
          "body":{"kind":"task","due":"2026-01-04T08:30:00.500Z"}},
         {"id":"c2","title":"data pura","createdAt":"2026-01-02T10:00:00Z",
          "body":{"kind":"milestone","target":"2026-02-01"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertEqual(result.tasks[0].anchorDate.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-01-04T08:30:00Z")!.timeIntervalSince1970 + 0.5,
                       accuracy: 0.01)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                    from: result.tasks[1].anchorDate)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 2)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 23)
        XCTAssertEqual(comps.minute, 59)
    }

    func testUnknownReminderOffsetKeepsTask() throws {
        let json = """
        [{"id":"d1","title":"offset novo","createdAt":"2026-01-02T10:00:00Z",
          "body":{"kind":"task","due":"2026-01-03T12:00:00Z"},
          "reminders":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","trigger":{"kind":"offset","offset":"10 minutes before"},"fired":false}]}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks[0].reminders.count, 1)
        XCTAssertEqual(result.tasks[0].reminders[0].trigger, .offset(.atTime))
    }

    func testMalformedReminderIsDroppedButTaskSurvives() throws {
        let json = """
        [{"id":"d2","title":"reminder quebrado","createdAt":"2026-01-02T10:00:00Z",
          "body":{"kind":"task","due":"2026-01-03T12:00:00Z"},
          "reminders":[{"id":"nao-e-uuid","trigger":{"kind":"offset","offset":"At time"},"fired":false},
                       {"id":"11111111-2222-3333-4444-555555555555","trigger":{"kind":"absolute","date":"2026-01-03T11:00:00Z"},"fired":false}]}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertEqual(result.tasks[0].reminders.count, 1)
    }

    func testMissingOptionalScalarsUseDefaults() throws {
        let json = """
        [{"id":"e1","modifiedAt":"2026-01-02T10:00:00Z","status":"arquivada","priority":"altissima",
          "orderIndex":"7","tagIds":null,"isAllDay":"sim",
          "body":{"kind":"task","due":"2026-01-03T12:00:00Z"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.droppedCount, 0)
        let task = result.tasks[0]
        XCTAssertEqual(task.title, "")
        XCTAssertEqual(task.status, .pending)
        XCTAssertEqual(task.priority, .unset)
        XCTAssertEqual(task.orderIndex, 0)
        XCTAssertEqual(task.tagIds, [])
        XCTAssertNil(task.isAllDay)
        XCTAssertEqual(task.createdAt, ISO8601DateFormatter().date(from: "2026-01-02T10:00:00Z"))
    }

    func testTaskWithoutIDIsDroppedAndCounted() throws {
        let json = """
        [\(canonical),
         {"title":"sem id","createdAt":"2026-01-02T10:00:00Z","body":{"kind":"task","due":"2026-01-03T12:00:00Z"}}]
        """
        let result = try decode(json)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.droppedCount, 1)
        XCTAssertEqual(result.dropReasons.count, 1)
        XCTAssertTrue(result.dropReasons[0].contains("id"))
    }

    func testRealVaultPayloadDecodesFully() throws {
        let dir = "/mnt/garime/state/tasks"
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
            throw XCTSkip("vault indisponivel neste ambiente")
        }
        let files = names.filter { $0.hasSuffix(".json") && !$0.contains(".sync-conflict-") }.sorted()
        try XCTSkipIf(files.isEmpty, "vault vazio")
        var parts: [Data] = []
        for name in files {
            guard let data = fm.contents(atPath: dir + "/" + name), !data.isEmpty,
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            parts.append(data)
        }
        var payload = Data("[".utf8)
        for (index, part) in parts.enumerated() {
            if index > 0 { payload.append(Data(",".utf8)) }
            payload.append(part)
        }
        payload.append(Data("]".utf8))

        let result = try BridgeTasksRepository.decodeTasks(from: payload)
        print("VAULT payload=\(parts.count) decoded=\(result.tasks.count) dropped=\(result.droppedCount)")
        XCTAssertEqual(result.droppedCount, 0, "\(result.dropReasons)")
        XCTAssertEqual(result.tasks.count, parts.count)
    }
}
