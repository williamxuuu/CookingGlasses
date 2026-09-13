import XCTest
@testable import CookingCore

final class WaterBoilSpoonTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let machine = RecipeStateMachine()

    private func event(_ event: CookingEvent, at seconds: Double, confidence: Double = 0.96) -> CookingObservation {
        .init(event: event, confidence: confidence, estimatedEventTimestamp: now.addingTimeInterval(seconds))
    }

    func testSingleStepRequiresAllThreeEventsInOrderWithoutTimers() throws {
        var session = CookingSession(recipe: SampleRecipes.waterBoilSpoonTest, now: now)
        XCTAssertEqual(session.recipe.steps.count, 1)
        XCTAssertEqual(session.expectedEvents, [.waterAddedToPot])
        for wrong in [CookingEvent.waterRollingBoil, .woodenSpoonInserted] {
            if case .ignored = machine.apply(event(wrong, at: 1), to: &session, now: now.addingTimeInterval(2)) {} else {
                XCTFail("Out-of-order checkpoint accepted")
            }
        }
        XCTAssertEqual(machine.apply(event(.waterAddedToPot, at: 3), to: &session, now: now.addingTimeInterval(10)), .accepted)
        XCTAssertEqual(session.expectedEvents, [.waterRollingBoil])
        XCTAssertTrue(session.completedStepIDs.isEmpty)
        XCTAssertEqual(session.observedAt(.waterAddedToPot), now.addingTimeInterval(3))
        let encoded = try JSONEncoder().encode(session)
        session = try JSONDecoder().decode(CookingSession.self, from: encoded)
        XCTAssertEqual(session.expectedEvents, [.waterRollingBoil])
        let beforeDuplicate = session
        if case .ignored = machine.apply(event(.waterAddedToPot, at: 11), to: &session, now: now.addingTimeInterval(12)) {} else {
            XCTFail("Duplicate checkpoint accepted")
        }
        XCTAssertEqual(session, beforeDuplicate)
        XCTAssertEqual(machine.apply(event(.waterRollingBoil, at: 180), to: &session, now: now.addingTimeInterval(184)), .accepted)
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(session.expectedEvents, [.woodenSpoonInserted])
        let request = CookingVisionRequest(recipe: session.recipe, step: session.visionStep, frames: [])
        XCTAssertEqual(request.expectedEvents, ["wooden_spoon_inserted"])
        XCTAssertEqual(machine.apply(event(.woodenSpoonInserted, at: 190), to: &session, now: now.addingTimeInterval(195)), .accepted)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.expectedEvents.isEmpty)
        XCTAssertTrue(session.timers.isEmpty)
    }

    func testCheckpointConfirmationUndoAndResetPreserveEvidenceBoundaries() {
        var session = CookingSession(recipe: SampleRecipes.waterBoilSpoonTest, now: now)
        XCTAssertEqual(machine.apply(event(.waterAddedToPot, at: 1, confidence: 0.6), to: &session, now: now.addingTimeInterval(2)), .needsConfirmation)
        XCTAssertNil(session.observedAt(.waterAddedToPot))
        machine.confirmPending(&session, now: now.addingTimeInterval(4))
        XCTAssertEqual(session.observedAt(.waterAddedToPot), now.addingTimeInterval(1))
        let oldRevision = session.revision
        _ = machine.apply(event(.waterRollingBoil, at: 10), to: &session, now: now.addingTimeInterval(11))
        machine.undo(&session, now: now.addingTimeInterval(12))
        XCTAssertEqual(session.expectedEvents, [.waterRollingBoil])
        XCTAssertNotNil(session.observedAt(.waterAddedToPot))
        XCTAssertNil(session.observedAt(.waterRollingBoil))
        if case .ignored = machine.apply(event(.waterRollingBoil, at: 13), to: &session, now: now.addingTimeInterval(14), expectedRevision: oldRevision) {} else {
            XCTFail("Old in-flight response survived undo")
        }
        machine.correct(&session, toStepIndex: 0, now: now.addingTimeInterval(15))
        XCTAssertEqual(session.expectedEvents, [.waterAddedToPot])
        XCTAssertNil(session.observedAt(.waterAddedToPot))
        if case .ignored = machine.apply(event(.waterAddedToPot, at: 14), to: &session, now: now.addingTimeInterval(16)) {} else {
            XCTFail("Old video survived checkpoint reset")
        }
    }

    func testOldRecipeWithoutCheckpointFieldStillDecodes() throws {
        let data = try JSONEncoder().encode(SampleRecipes.panSearedChicken)
        let recipe = try JSONDecoder().decode(Recipe.self, from: data)
        XCTAssertNil(recipe.steps.first?.requiredEventSequence)
        XCTAssertEqual(recipe, SampleRecipes.panSearedChicken)
    }
}
