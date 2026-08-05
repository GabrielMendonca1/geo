import XCTest

final class TerminalGesturesUITests: XCTestCase {
    private func launchTerminal() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-geoTab", "terminal", "-geoSession", "vm:mobile"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 6)
        return app
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testTwoFingerTapEntersSelectionMode() {
        let app = launchTerminal()
        capture("terminal-idle")
        let surface = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        surface.twoFingerTap()
        Thread.sleep(forTimeInterval: 2)
        capture("levaQ-selection")
        XCTAssertTrue(app.staticTexts["seleção"].waitForExistence(timeout: 5))
    }

    func testOverflowMenuShowsPasteAndUpload() {
        let app = launchTerminal()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.096)).tap()
        Thread.sleep(forTimeInterval: 2)
        capture("levaQ-menu")
        XCTAssertTrue(app.buttons["colar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["enviar foto"].exists)
        XCTAssertTrue(app.buttons["enviar arquivo"].exists)
    }
}
