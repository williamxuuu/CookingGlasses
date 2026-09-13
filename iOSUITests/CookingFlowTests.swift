import XCTest

final class CookingFlowTests: XCTestCase {
    func testWaterBoilSpoonCheckpoints() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let start = app.buttons["start_recipe"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        if !start.isHittable { app.swipeUp() }
        start.tap()
        app.buttons["recipe_water-boil-spoon-test"].tap()
        let begin = app.buttons["begin_cooking"]
        if !begin.isHittable { app.swipeUp() }
        begin.tap()
        XCTAssertTrue(app.staticTexts["Fill, boil, then add the spoon"].waitForExistence(timeout: 10))
        attach(app, name: "Water test before observations")
        app.buttons["open_debug"].tap()
        app.buttons["Start Cooking Watch"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) { springboard.alerts.buttons["Allow"].tap() }
        let water = app.buttons["Water added to pot"]
        if !water.isHittable { app.swipeUp() }
        XCTAssertTrue(water.waitForExistence(timeout: 10))
        water.tap()
        XCTAssertTrue(app.staticTexts["Accepted · state updated"].waitForExistence(timeout: 5))
        app.buttons["Rolling boil detected"].tap()
        XCTAssertTrue(app.staticTexts["Accepted · state updated"].waitForExistence(timeout: 5))
        app.buttons["Wooden spoon inserted"].tap()
        XCTAssertTrue(app.staticTexts["Accepted · state updated"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Step completed"].waitForExistence(timeout: 5))
        attach(app, name: "Water test after all observations")
    }

    func testChickenPlacementFlipAndReconnect() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        attach(app, name: "Home")
        let start = app.buttons["start_recipe"]
        if !start.isHittable { app.swipeUp() }
        XCTAssertTrue(start.waitForExistence(timeout: 10)); start.tap()
        let chicken = app.buttons["recipe_pan-seared-chicken"]
        if !chicken.isHittable { app.swipeUp() }
        chicken.tap()
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
