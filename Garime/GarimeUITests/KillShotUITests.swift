import XCTest

final class KillShotUITests: XCTestCase {
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testLongPressOnSessionRowShowsKill() {
        let app = XCUIApplication()
        app.launchArguments = ["-geoTab", "terminal", "-geoSessions"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)
        capture("levaAH-list")
        let row = app.staticTexts["mobile"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.6)
        Thread.sleep(forTimeInterval: 2.5)
        capture("levaAH-kill")
        XCTAssertTrue(app.buttons["matar sessão"].waitForExistence(timeout: 5))
    }

    func testLongPressOnVMAgentRowShowsKill() {
        let app = XCUIApplication()
        app.launchArguments = ["-geoTab", "terminal", "-geoSessions"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)
        let row = app.staticTexts["claude"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.6)
        Thread.sleep(forTimeInterval: 2.5)
        capture("levaAH-kill-agent")
        XCTAssertTrue(app.buttons["matar sessão"].waitForExistence(timeout: 5))
    }

    func testLongPressOnMacAgentRowHasNoKill() {
        let app = XCUIApplication()
        app.launchArguments = ["-geoTab", "terminal", "-geoSessions"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)
        let row = app.staticTexts["herdr"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.6)
        Thread.sleep(forTimeInterval: 2.5)
        capture("levaAH-mac-agent")
        XCTAssertTrue(app.buttons["abrir no terminal"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["matar sessão"].exists)
    }
}
