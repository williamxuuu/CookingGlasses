import XCTest
@testable import CookingCore

final class TimerPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sessionWithTimers() -> CookingSession {
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        TimerManager.start(for: session.recipe.steps[3], in: &session, now: now)
        TimerManager.start(for: session.recipe.steps[5], in: &session, now: now.addingTimeInterval(30))
        return session
    }

    func testIndependentTimersUseAbsoluteDeadlinesAcrossRelaunch() throws {
        let session = sessionWithTimers()
        let restored = try JSONDecoder().decode(CookingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.timers[0].remaining(at: now.addingTimeInterval(100)), 200)
        XCTAssertEqual(restored.timers[1].remaining(at: now.addingTimeInterval(100)), 170)
        XCTAssertTrue(restored.timers[0].isExpired(at: now.addingTimeInterval(301)))
        XCTAssertEqual(restored.currentStepIndex, 0)
    }

    func testPauseSurvivesRelaunchThenResumePreservesRemainingTime() throws {
        var session = sessionWithTimers()
        let id = session.timers[0].id
        TimerManager.pause(id: id, in: &session, now: now.addingTimeInterval(100))
        session = try JSONDecoder().decode(CookingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(10_000)), 200)
        XCTAssertFalse(session.timers[0].isExpired(at: now.addingTimeInterval(10_000)))
        TimerManager.resume(id: id, in: &session, now: now.addingTimeInterval(10_000))
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(10_050)), 150)
        XCTAssertEqual(session.timers[0].startTime, now)
        XCTAssertTrue(session.timers[1].isExpired(at: now.addingTimeInterval(10_050)))
    }

    func testExtendRunningPausedAndExpiredTimers() {
        var session = sessionWithTimers()
        let id = session.timers[0].id
        TimerManager.extend(id: id, in: &session, by: 60, now: now.addingTimeInterval(100))
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(100)), 260)
        TimerManager.pause(id: id, in: &session, now: now.addingTimeInterval(110))
        TimerManager.extend(id: id, in: &session, by: 60, now: now.addingTimeInterval(500))
        XCTAssertTrue(session.timers[0].isPaused)
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(1_000)), 310)
        TimerManager.resume(id: id, in: &session, now: now.addingTimeInterval(1_000))
        TimerManager.refresh(in: &session, now: now.addingTimeInterval(2_000))
        XCTAssertTrue(session.timers[0].isCompleted)
        TimerManager.extend(id: id, in: &session, by: 60, now: now.addingTimeInterval(2_100))
        XCTAssertFalse(session.timers[0].isCompleted)
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(2_100)), 60)
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(2_130)), 30)
    }

    func testDuplicateDismissedTimersCannotRestartAndInvalidExtensionsAreIgnored() {
        var session = sessionWithTimers()
        let id = session.timers[0].id
        TimerManager.dismiss(id: id, in: &session)
        TimerManager.start(for: session.recipe.steps[3], in: &session, now: now.addingTimeInterval(100))
        XCTAssertEqual(session.timers.count, 2)
        XCTAssertTrue(session.timers[0].isDismissed)
        let original = session
        for seconds in [-1.0, 0, .infinity, .nan] {
            TimerManager.extend(id: id, in: &session, by: seconds, now: now)
        }
        XCTAssertEqual(session, original)
    }

    func testPersistenceAtomicSaveLoadClearAndCorruptFileRejection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionPersistence(url: directory.appendingPathComponent("session.json"))
        XCTAssertNil(try storage.load())
        let session = sessionWithTimers()
        try storage.save(session)
        XCTAssertEqual(try storage.load(), session)
        try Data("{broken".utf8).write(to: storage.url)
        XCTAssertThrowsError(try storage.load())
        try storage.clear()
        try storage.clear()
        XCTAssertNil(try storage.load())
    }

    func testPersistenceRejectsInvalidIndexAndDuplicateTimerState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionPersistence(url: directory.appendingPathComponent("session.json"))
        var session = sessionWithTimers()
        session.currentStepIndex = 900
        XCTAssertThrowsError(try storage.save(session))
        session.currentStepIndex = 0
        session.timers.append(session.timers[0])
        XCTAssertThrowsError(try storage.save(session))
    }

    func testManualTimersShareStepWithRecipeTimerAndPersistIndependently() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = SessionPersistence(url: directory.appendingPathComponent("session.json"))
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        RecipeStateMachine().correct(&session, toStepIndex: 3, now: now)
        XCTAssertTrue(TimerManager.startManual(label: "Pasta", duration: 600, in: &session, now: now))
        XCTAssertTrue(TimerManager.startManual(label: "Sauce", duration: 180, in: &session, now: now))
        TimerManager.start(for: session.currentStep, in: &session, now: now)
        TimerManager.start(for: session.currentStep, in: &session, now: now.addingTimeInterval(1))
        XCTAssertEqual(session.timers.count, 3)
        XCTAssertEqual(session.timers.filter(\.isManual).count, 2)
        XCTAssertEqual(Set(session.timers.map(\.associatedStepID)), ["chicken-first-side"])
        TimerManager.pause(id: session.timers[0].id, in: &session, now: now.addingTimeInterval(20))
        try storage.save(session)
        let restored = try XCTUnwrap(storage.load())
        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.timers[0].remaining(at: now.addingTimeInterval(100)), 580)
        XCTAssertEqual(restored.timers[1].remaining(at: now.addingTimeInterval(100)), 80)
        XCTAssertEqual(restored.timers[2].remaining(at: now.addingTimeInterval(100)), 200)
        var duplicateRecipeTimer = session.timers[2]
        duplicateRecipeTimer.id = UUID()
        session.timers.append(duplicateRecipeTimer)
        XCTAssertThrowsError(try storage.save(session))
    }

    func testStepCompletionLeavesManualTimersRunningAndCorrectionOnlyResetsDownstream() {
        let machine = RecipeStateMachine()
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        machine.correct(&session, toStepIndex: 2, now: now)
        TimerManager.startManual(label: "Pasta", duration: 600, in: &session, now: now)
        machine.markDone(&session, now: now)
        TimerManager.startManual(label: "Sauce", duration: 180, in: &session, now: now)
        let originalManual = session.timers.filter(\.isManual)
        machine.markDone(&session, now: now.addingTimeInterval(10))
        XCTAssertEqual(session.timers.filter(\.isManual), originalManual)
        XCTAssertTrue(session.timers.first(where: { !$0.isManual })?.isCompleted == true)
        machine.correct(&session, toStepIndex: 3, now: now.addingTimeInterval(20))
        XCTAssertEqual(session.timers, [originalManual[0]])
        XCTAssertEqual(session.timers[0].label, "Pasta")
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(20)), 580)
    }

    func testManualTimerValidationAndCapacityCannotBeBypassedByExtension() {
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        for duration in [0, -1, Double.nan, Double.infinity, 86_400.1] {
            XCTAssertFalse(TimerManager.startManual(label: "Pasta", duration: duration, in: &session, now: now))
        }
        for label in ["", " \n ", String(repeating: "a", count: 51)] {
            XCTAssertFalse(TimerManager.startManual(label: label, duration: 60, in: &session, now: now))
        }
        XCTAssertTrue(session.timers.isEmpty)
        for index in 1...8 {
            XCTAssertTrue(TimerManager.startManual(label: " Timer \(index) ", duration: 60, in: &session, now: now))
        }
        XCTAssertEqual(session.timers[0].label, "Timer 1")
        XCTAssertFalse(TimerManager.startManual(label: "Ninth", duration: 60, in: &session, now: now))
        TimerManager.refresh(in: &session, now: now.addingTimeInterval(100))
        XCTAssertFalse(TimerManager.startManual(label: "Ninth", duration: 60, in: &session, now: now))
        let dismissedID = session.timers[0].id
        TimerManager.dismiss(id: dismissedID, in: &session)
        XCTAssertTrue(TimerManager.startManual(label: String(repeating: "a", count: 50), duration: 86_400,
                                             in: &session, now: now))
        TimerManager.extend(id: dismissedID, in: &session, by: 60, now: now.addingTimeInterval(100))
        XCTAssertTrue(session.timers[0].isDismissed)
        let maximumTimerID = session.timers.last!.id
        TimerManager.extend(id: maximumTimerID, in: &session, by: 1, now: now)
        XCTAssertEqual(session.timers.last?.duration, 86_400)
        XCTAssertEqual(session.timers.filter { $0.isManual && !$0.isDismissed }.count, 8)
    }

    func testPreManualTimerSavedSessionsDecodeAsRecipeTimers() throws {
        let session = sessionWithTimers()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        var timers = try XCTUnwrap(json["timers"] as? [[String: Any]])
        for index in timers.indices { timers[index].removeValue(forKey: "isManual") }
        json["timers"] = timers
        let restored = try JSONDecoder().decode(CookingSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored, session)
        XCTAssertTrue(restored.timers.allSatisfy { !$0.isManual })
    }

    func testUndoCookingActionPreservesNewSideTimersAndTheirLaterEdits() {
        let machine = RecipeStateMachine()
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        machine.correct(&session, toStepIndex: 2, now: now)
        TimerManager.startManual(label: "Pasta", duration: 600, in: &session, now: now)
        machine.markDone(&session, now: now)
        TimerManager.extend(id: session.timers[0].id, in: &session, by: 60, now: now.addingTimeInterval(10))
        TimerManager.pause(id: session.timers[0].id, in: &session, now: now.addingTimeInterval(20))
        TimerManager.startManual(label: "Sauce", duration: 180, in: &session, now: now.addingTimeInterval(20))
        let sideTimers = session.timers.filter(\.isManual)
        machine.undo(&session, now: now.addingTimeInterval(30))
        XCTAssertEqual(session.currentStep.id, "chicken-add")
        XCTAssertEqual(session.timers, sideTimers)
        XCTAssertTrue(session.timers[0].isPaused)
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(30)), 640)
        XCTAssertEqual(session.timers[1].remaining(at: now.addingTimeInterval(30)), 170)
    }

    func testUndoCorrectionRestoresRemovedManualTimersWithoutExceedingCapacity() {
        let machine = RecipeStateMachine()
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        machine.correct(&session, toStepIndex: 3, now: now)
        for index in 1...8 {
            TimerManager.startManual(label: "Original \(index)", duration: 600, in: &session, now: now)
        }
        let originalTimers = session.timers
        machine.correct(&session, toStepIndex: 2, now: now.addingTimeInterval(10))
        XCTAssertTrue(session.timers.isEmpty)
        TimerManager.startManual(label: "New", duration: 180, in: &session, now: now.addingTimeInterval(10))
        machine.undo(&session, now: now.addingTimeInterval(20))
        XCTAssertEqual(session.currentStepIndex, 2)
        XCTAssertEqual(session.timers.count, 1)
        XCTAssertTrue(session.canUndo)
        XCTAssertTrue(session.lastAction?.contains("Dismiss newer side timers") == true)
        TimerManager.dismiss(id: session.timers[0].id, in: &session)
        machine.undo(&session, now: now.addingTimeInterval(30))
        XCTAssertEqual(session.currentStepIndex, 3)
        XCTAssertEqual(Array(session.timers.prefix(8)), originalTimers)
        XCTAssertEqual(session.timers.filter { $0.isManual && !$0.isDismissed }.count, 8)
        XCTAssertFalse(session.canUndo)
    }
}
