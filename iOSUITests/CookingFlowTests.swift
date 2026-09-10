import XCTest

final class CookingFlowTests: XCTestCase {
    func testChickenPlacementFlipAndReconnect() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        attach(app, name: "Home")
        let start = app.buttons["start_recipe"]
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe_")).firstMatch.tap()
        let begin = app.buttons["begin_cooking"]
        if !begin.isHittable { app.swipeUp() }
        begin.tap()
        let done = app.buttons["mark_done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap(); done.tap()
        attach(app, name: "Chicken placement step")
        app.buttons["open_debug"].tap()
        app.buttons["Start Cooking Watch"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) { springboard.alerts.buttons["Allow"].tap() }
        let added = app.buttons["Chicken Added To Pan"]
        if !added.isHittable { app.swipeUp() }
        XCTAssertTrue(added.waitForExistence(timeout: 10)); added.tap()
        XCTAssertTrue(app.staticTexts["Accepted · state updated"].waitForExistence(timeout: 5))
        added.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ignored ·")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Chicken Flipped"].tap()
        XCTAssertTrue(app.staticTexts["Accepted · state updated"].waitForExistence(timeout: 5))
        app.swipeDown()
        app.buttons["Simulate disconnect"].tap()
        XCTAssertTrue(app.staticTexts["Cooking Watch paused — timers still running."].waitForExistence(timeout: 5))
        app.buttons["Connect / reconnect"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Cook the second side"].waitForExistence(timeout: 5))
        app.swipeUp()
        attach(app, name: "Second side timer after reconnect")
        XCTAssertTrue(app.staticTexts["Chicken second side"].firstMatch.waitForExistence(timeout: 5))
        // Process-termination persistence is checked in CookingCore's deterministic
        // disk round-trip tests. XCUITest termination itself is unreliable on some
        // host runtimes; this test covers the interactive cooking/reconnect flow.
    }
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
