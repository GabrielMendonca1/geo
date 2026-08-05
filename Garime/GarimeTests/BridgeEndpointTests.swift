import XCTest
@testable import Garime

final class BridgeEndpointTests: XCTestCase {
    func testHealthPathIsCorrect() {
        XCTAssertEqual(BridgeEndpoint.health.path, "/health")
    }

    func testTaskCRUDPathsAreCorrect() {
        let id = "task-123"
        XCTAssertEqual(BridgeEndpoint.tasksList.path, "/tasks")
        XCTAssertEqual(BridgeEndpoint.tasksCreate.path, "/tasks")
        XCTAssertEqual(BridgeEndpoint.taskComplete(id: id).path, "/tasks/task-123/complete")
        XCTAssertEqual(BridgeEndpoint.taskReopen(id: id).path, "/tasks/task-123/reopen")
        XCTAssertEqual(BridgeEndpoint.taskDelete(id: id).path, "/tasks/task-123")
    }

    func testPercentEncodingInTermSession() {
        XCTAssertEqual(
            BridgeEndpoint.termStream(session: "my session&tab=1").path,
            "/term/stream?session=my%20session%26tab%3D1"
        )
    }

    func testAttachAgentPathEncodesPaneColon() {
        XCTAssertEqual(
            BridgeEndpoint.termAttachAgent(project: "garime", pane: "w1:p3").path,
            "/term/attach-agent?project=garime&pane=w1%3Ap3"
        )
    }

    func testAttachHerdrPathEncodesProject() {
        XCTAssertEqual(
            BridgeEndpoint.termAttachHerdr(project: "meu projeto").path,
            "/term/attach-herdr?project=meu%20projeto"
        )
    }

    func testPercentEncodingInTaskID() {
        XCTAssertEqual(
            BridgeEndpoint.taskComplete(id: "work/50% #1").path,
            "/tasks/work%2F50%25%20%231/complete"
        )
    }
}
