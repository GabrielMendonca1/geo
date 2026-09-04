import XCTest

final class StartAgentShotUITests: XCTestCase {
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testLongPressOnSessionRowOffersStartAgent() {
        let app = XCUIApplication()
        app.launchArguments = ["-geoTab", "terminal", "-geoSessions"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)
        let row = app.staticTexts["mobile"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.6)
        let start = app.buttons["iniciar agente"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        Thread.sleep(forTimeInterval: 2.5)
        capture("levaAH-start")
        XCTAssertTrue(app.buttons["claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pi"].exists)
        XCTAssertTrue(app.buttons["codex"].exists)
    }
}
