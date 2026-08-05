import XCTest

final class ComposerShotsUITests: XCTestCase {
    private func launch(draft: String = "") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-geoTab", "terminal", "-geoChat", "garime|w1:p3|claude|working|composer"]
        if !draft.isEmpty {
            app.launchArguments += ["-geoDraft", draft]
        }
        app.launch()
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func field(_ app: XCUIApplication) -> XCUIElement {
        let view = app.textViews.firstMatch
        return view.exists ? view : app.textFields.firstMatch
    }

    func testCommandMenuShot() {
        let app = launch(draft: "/g")
        XCTAssertTrue(field(app).waitForExistence(timeout: 10))
        sleep(3)
        shot("menu")
    }

    func testAttachMenuShot() {
        let app = launch()
        XCTAssertTrue(field(app).waitForExistence(timeout: 10))
        let plus = app.buttons["Add"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        sleep(2)
        shot("anexo")
    }

    func testDictationShot() {
        let app = launch()
        XCTAssertTrue(field(app).waitForExistence(timeout: 10))
        let mic = app.buttons["ditar"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()
        sleep(3)
        shot("audio")
    }
}
