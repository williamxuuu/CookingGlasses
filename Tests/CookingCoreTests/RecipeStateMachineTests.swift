import XCTest
@testable import CookingCore

final class RecipeStateMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let machine = RecipeStateMachine()

    private func readyForChicken() -> CookingSession {
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        machine.markDone(&session, now: now)
        machine.markDone(&session, now: now)
        return session
    }

    private func observation(_ event: CookingEvent, after seconds: TimeInterval = 1,
                             confidence: Double = 0.96) -> CookingObservation {
        CookingObservation(event: event, confidence: confidence, estimatedEventTimestamp: now.addingTimeInterval(seconds))
    }

    func testPlacementStartsExactlyOneTimerAndRepeatedSightingsAreIgnored() {
        var session = readyForChicken()
        XCTAssertEqual(machine.apply(observation(.chickenAddedToPan), to: &session, now: now.addingTimeInterval(2)), .accepted)
        XCTAssertEqual(session.currentStep.id, "chicken-first-side")
        XCTAssertTrue(session.completedStepIDs.contains("chicken-add"))
        XCTAssertEqual(session.timers.count, 1)
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(2)), 299)
        let revision = session.revision
        if case .ignored = machine.apply(observation(.chickenAddedToPan, after: 3), to: &session,
                                         now: now.addingTimeInterval(3)) {} else { XCTFail("Duplicate should be ignored") }
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.timers.count, 1)
    }

    func testFlipDuringActiveFirstSideStartsSecondSideWithoutWaitingForExpiry() {
        var session = readyForChicken()
        machine.apply(observation(.chickenAddedToPan), to: &session, now: now.addingTimeInterval(1))
        XCTAssertGreaterThan(session.timers[0].remaining(at: now.addingTimeInterval(60)), 0)
        XCTAssertTrue(session.currentStep.expectedEvents.contains(.chickenFlipped))
        XCTAssertEqual(machine.apply(observation(.chickenFlipped, after: 60), to: &session,
                                     now: now.addingTimeInterval(61)), .accepted)
        XCTAssertEqual(session.currentStep.id, "chicken-second-side")
        XCTAssertTrue(session.completedStepIDs.isSuperset(of: ["chicken-first-side", "chicken-flip"]))
        XCTAssertEqual(session.timers.count, 2)
        XCTAssertTrue(session.timers[0].isCompleted)
        XCTAssertTrue(session.timers[0].isDismissed)
        XCTAssertEqual(session.timers[1].remaining(at: now.addingTimeInterval(61)), 239)
    }

    func testRemovalStartsRestAndNeverClaimsSafeTemperature() {
        var session = readyForChicken()
        machine.apply(observation(.chickenAddedToPan), to: &session, now: now.addingTimeInterval(1))
        machine.apply(observation(.chickenFlipped, after: 60), to: &session, now: now.addingTimeInterval(60))
        XCTAssertEqual(machine.apply(observation(.chickenRemovedFromPan, after: 120), to: &session,
                                     now: now.addingTimeInterval(120)), .accepted)
        XCTAssertEqual(session.currentStep.id, "chicken-rest")
        XCTAssertEqual(session.timers.last?.duration, 180)
        XCTAssertTrue(session.lastAction?.contains("verify 165°F / 74°C") == true)
        XCTAssertFalse(session.isFinished)
    }

    func testNavigationCanBrowseFreelyButCannotCompleteStepsOrStartTimers() {
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        machine.navigate(&session, offset: 1)
        XCTAssertEqual(session.currentStepIndex, 1)
        machine.navigate(&session, offset: 7)
        XCTAssertEqual(session.currentStepIndex, 7)
        machine.markDone(&session, now: now)
        XCTAssertTrue(session.completedStepIDs.isEmpty)
        XCTAssertTrue(session.timers.isEmpty)
        session = readyForChicken()
        let completed = session.completedStepIDs
        machine.navigate(&session, offset: -1)
        XCTAssertEqual(session.currentStepIndex, 1)
        machine.navigate(&session, offset: 1)
        XCTAssertEqual(session.currentStepIndex, 2)
        XCTAssertEqual(session.completedStepIDs, completed)
        XCTAssertTrue(session.timers.isEmpty)
        machine.navigate(&session, offset: 1)
        XCTAssertEqual(session.currentStepIndex, 3)
        machine.markDone(&session, now: now)
        XCTAssertEqual(session.completedStepIDs, completed)
        XCTAssertTrue(session.timers.isEmpty)
    }

    func testManualCompletionStartsNextTimerButRevisitingDoneStepCannotRestartIt() {
        var session = readyForChicken()
        machine.markDone(&session, now: now)
        XCTAssertEqual(session.currentStep.id, "chicken-first-side")
        XCTAssertEqual(session.timers.count, 1)
        TimerManager.dismiss(id: session.timers[0].id, in: &session)
        machine.navigate(&session, offset: -1)
        machine.markDone(&session, now: now.addingTimeInterval(10))
        XCTAssertEqual(session.timers.count, 1)
        XCTAssertTrue(session.timers[0].isDismissed)
    }

    func testInvalidPrerequisitesBlockObservationAndMarkDoneEvenForCorruptedIndex() {
        var session = CookingSession(recipe: SampleRecipes.panSearedChicken, now: now)
        session.currentStepIndex = 2
        if case .ignored = machine.apply(observation(.chickenAddedToPan), to: &session,
                                         now: now.addingTimeInterval(1)) {} else { XCTFail("Prerequisites must be checked") }
        machine.markDone(&session, now: now)
        XCTAssertTrue(session.completedStepIDs.isEmpty)
        XCTAssertTrue(session.timers.isEmpty)
    }

    func testLowConfidenceNeedsHumanConfirmationAndCanBeRejected() {
        var session = readyForChicken()
        XCTAssertEqual(machine.apply(observation(.chickenAddedToPan, confidence: 0.6), to: &session,
                                     now: now.addingTimeInterval(1)), .needsConfirmation)
        XCTAssertEqual(session.currentStepIndex, 2)
        XCTAssertTrue(session.timers.isEmpty)
        XCTAssertNotNil(session.pendingObservation)
        machine.rejectPending(&session)
        machine.confirmPending(&session, now: now.addingTimeInterval(2))
        XCTAssertTrue(session.timers.isEmpty)
        XCTAssertEqual(machine.apply(observation(.chickenAddedToPan, after: 3, confidence: 0.7), to: &session,
                                     now: now.addingTimeInterval(3)), .needsConfirmation)
        let pendingRevision = session.revision
        machine.confirmPending(&session, now: now.addingTimeInterval(40))
        XCTAssertEqual(session.timers.count, 1)
        XCTAssertEqual(session.timers[0].remaining(at: now.addingTimeInterval(40)), 263)
        XCTAssertNil(session.pendingObservation)
        XCTAssertGreaterThan(session.revision, pendingRevision)
        if case .ignored = machine.apply(observation(.chickenFlipped, after: 41), to: &session,
                                         now: now.addingTimeInterval(41), expectedRevision: pendingRevision) {} else {
            XCTFail("Confirmation must invalidate observations from its prior recipe revision")
        }
        XCTAssertEqual(session.timers.count, 1)
    }

    func testNavigationInvalidatesPendingAndInFlightResponse() {
        var session = readyForChicken()
        let requestRevision = session.revision
        machine.apply(observation(.chickenAddedToPan, confidence: 0.5), to: &session, now: now.addingTimeInterval(1))
        machine.navigate(&session, offset: -1)
        machine.navigate(&session, offset: 1)
        machine.confirmPending(&session, now: now.addingTimeInterval(2))
        XCTAssertTrue(session.timers.isEmpty)
        if case .ignored = machine.apply(observation(.chickenAddedToPan, after: 2), to: &session,
                                         now: now.addingTimeInterval(2), expectedRevision: requestRevision) {} else {
            XCTFail("Stale response must not act after navigation")
        }
        XCTAssertEqual(session.currentStepIndex, 2)
    }

    func testOldFutureAndInvalidConfidenceObservationsCannotMutateState() {
        let invalid = [
            observation(.chickenAddedToPan, after: -1),
            observation(.chickenAddedToPan, after: 100),
            observation(.chickenAddedToPan, confidence: .nan),
            observation(.chickenAddedToPan, confidence: 1.1),
            observation(.uncertain), observation(.noRelevantEvent), observation(.chickenFlipped)
        ]
        for candidate in invalid {
            var session = readyForChicken()
            let original = session
            if case .ignored = machine.apply(candidate, to: &session, now: now.addingTimeInterval(10)) {} else {
                XCTFail("Invalid evidence accepted: \(candidate)")
            }
            XCTAssertEqual(session, original)
        }
        var session = readyForChicken()
        if case .ignored = machine.apply(observation(.chickenAddedToPan), to: &session,
                                         now: now.addingTimeInterval(40)) {} else { XCTFail("Too-old event accepted") }
    }

    func testManualCorrectionClearsDownstreamTimersAndDedupeButRejectsOldEvidence() {
        var session = readyForChicken()
        machine.apply(observation(.chickenAddedToPan), to: &session, now: now.addingTimeInterval(1))
        machine.apply(observation(.chickenFlipped, after: 60), to: &session, now: now.addingTimeInterval(60))
        machine.correct(&session, toStepIndex: 2, now: now.addingTimeInterval(70))
        XCTAssertEqual(session.completedStepIDs, ["chicken-season", "chicken-heat"])
        XCTAssertTrue(session.timers.isEmpty)
        if case .ignored = machine.apply(observation(.chickenAddedToPan, after: 69), to: &session,
                                         now: now.addingTimeInterval(71)) {} else { XCTFail("Old capture survived correction") }
        XCTAssertEqual(machine.apply(observation(.chickenAddedToPan, after: 71), to: &session,
                                     now: now.addingTimeInterval(71)), .accepted)
        XCTAssertEqual(session.timers.count, 1)
    }

    func testCorrectionPreservesEarlierTimerDeadlineAndPauseState() {
        var session = readyForChicken()
        machine.markDone(&session, now: now)
        TimerManager.pause(id: session.timers[0].id, in: &session, now: now.addingTimeInterval(20))
        let originalTimer = session.timers[0]
        machine.correct(&session, toStepIndex: 5, now: now.addingTimeInterval(60))
        XCTAssertEqual(session.currentStep.id, "chicken-second-side")
        XCTAssertEqual(session.timers, [originalTimer])
        XCTAssertTrue(session.timers[0].isPaused)
        XCTAssertFalse(session.timers[0].isCompleted)
        XCTAssertFalse(session.timers.contains { $0.associatedStepID == "chicken-second-side" })
    }

    func testUndoFlipRestoresOriginalFirstSideDeadlineAndInvalidatesResponse() {
        var session = readyForChicken()
        machine.apply(observation(.chickenAddedToPan), to: &session, now: now.addingTimeInterval(1))
        let firstSide = session.timers[0]
        let requestRevision = session.revision
        machine.apply(observation(.chickenFlipped, after: 60), to: &session, now: now.addingTimeInterval(60))
        machine.undo(&session, now: now.addingTimeInterval(62))
        XCTAssertEqual(session.currentStep.id, "chicken-first-side")
        XCTAssertEqual(session.timers, [firstSide])
        XCTAssertFalse(session.completedStepIDs.contains("chicken-flip"))
        XCTAssertFalse(session.canUndo)
        if case .ignored = machine.apply(observation(.chickenFlipped, after: 63), to: &session,
                                         now: now.addingTimeInterval(63), expectedRevision: requestRevision) {} else {
            XCTFail("Undo must invalidate requests")
        }
        XCTAssertEqual(machine.apply(observation(.chickenFlipped, after: 63), to: &session,
                                     now: now.addingTimeInterval(63), expectedRevision: session.revision), .accepted)
    }

    func testTimerExpiryCannotAdvanceRecipeOrCompleteFood() {
        var session = readyForChicken()
        machine.markDone(&session, now: now)
        let completed = session.completedStepIDs
        TimerManager.refresh(in: &session, now: now.addingTimeInterval(1_000))
        XCTAssertTrue(session.timers[0].isCompleted)
        XCTAssertEqual(session.currentStep.id, "chicken-first-side")
        XCTAssertEqual(session.completedStepIDs, completed)
        XCTAssertFalse(session.isFinished)
    }

    func testAllSampleRecipesHaveValidOrderAndPoultryTemperatureStaysVisible() {
        XCTAssertEqual(SampleRecipes.all.count, 3)
        for recipe in SampleRecipes.all {
            var session = CookingSession(recipe: recipe, now: now)
            for _ in recipe.steps { machine.markDone(&session, now: now) }
            XCTAssertTrue(session.isFinished, recipe.title)
        }
        for id in ["chicken-second-side", "chicken-remove", "chicken-rest"] {
            let step = SampleRecipes.panSearedChicken.steps.first { $0.id == id }!
            XCTAssertTrue(step.fullInstruction.contains("thermometer"))
            XCTAssertTrue(step.glassesInstruction.contains("165°F / 74°C"))
        }
    }
}
