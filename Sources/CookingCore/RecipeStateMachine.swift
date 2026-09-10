import Foundation

public enum ObservationResult: Equatable, Sendable {
    case accepted
    case needsConfirmation
    case ignored(String)
}

/// Structured vision observations are evidence, never executable commands.
public struct RecipeStateMachine: Sendable {
    public let confidenceThreshold: Double
    public let maximumObservationAge: TimeInterval
    public let futureTolerance: TimeInterval

    public init(confidenceThreshold: Double = 0.85, maximumObservationAge: TimeInterval = 30,
                futureTolerance: TimeInterval = 5) {
        self.confidenceThreshold = min(1, max(0, confidenceThreshold))
        self.maximumObservationAge = max(1, maximumObservationAge)
        self.futureTolerance = max(0, futureTolerance)
    }

    /// Navigation is read-only with respect to cooking progress and timer state.
    public func navigate(_ session: inout CookingSession, offset: Int) {
        let target = min(max(session.currentStepIndex + min(max(offset, -session.recipe.steps.count),
                                                           session.recipe.steps.count), 0),
                         session.recipe.steps.count - 1)
        guard target != session.currentStepIndex else { return }
        session.currentStepIndex = target
        invalidatePending(&session)
        session.revision += 1
        session.lastAction = nil
    }

    public func markDone(_ session: inout CookingSession, now: Date = Date()) {
        guard !session.isFinished,
              session.currentStep.prerequisiteStepIDs.isSubset(of: session.completedStepIDs) else { return }
        session.undoSnapshot = SessionSnapshot(session)
        let step = session.currentStep
        let wasAlreadyComplete = session.completedStepIDs.contains(step.id)
        if !wasAlreadyComplete {
            session.completedStepIDs.insert(step.id)
            TimerManager.complete(stepID: step.id, in: &session)
        }
        advance(&session, startTimer: !wasAlreadyComplete, timerStart: now)
        session.lastAction = "\(step.title) marked done"
        session.observationNotBefore = max(session.observationNotBefore, now)
        session.revision += 1
        invalidatePending(&session)
    }

    /// Capture session.revision with an AI request and pass it back here. This prevents a
    /// response from a previous viewed step, manual correction, or undo from mutating state.
    @discardableResult
    public func apply(_ observation: CookingObservation, to session: inout CookingSession,
                      now: Date = Date(), expectedRevision: Int? = nil) -> ObservationResult {
        if let expectedRevision, expectedRevision != session.revision {
            return .ignored("Recipe state changed while analysis was in flight")
        }
        if let reason = invalidReason(observation, in: session, now: now) { return .ignored(reason) }
        if observation.confidence < confidenceThreshold || !session.currentStep.allowsAutomaticProgression {
            session.pendingObservation = observation
            session.pendingRevision = session.revision
            return .needsConfirmation
        }
        perform(observation, in: &session)
        return .accepted
    }

    public func confirmPending(_ session: inout CookingSession, now: Date = Date()) {
        guard let observation = session.pendingObservation, session.pendingRevision == session.revision,
              invalidReason(observation, in: session, now: now, checkAge: false) == nil else {
            invalidatePending(&session)
            return
        }
        // A human confirmation may take longer than the network freshness window. The
        // original timestamp still determines the timer; never grant extra cooking time.
        perform(observation, in: &session)
        session.observationNotBefore = max(session.observationNotBefore, now)
    }

    public func rejectPending(_ session: inout CookingSession) {
        guard session.pendingObservation != nil else { return }
        invalidatePending(&session)
        session.revision += 1
        session.lastAction = "Observation dismissed"
    }

    /// Explicitly resets this step and everything after it. Earlier steps are confirmed by
    /// the user's correction; timers do not start until an explicit action starts them.
    public func correct(_ session: inout CookingSession, toStepIndex target: Int, now: Date = Date()) {
        guard session.recipe.steps.indices.contains(target) else { return }
        session.undoSnapshot = SessionSnapshot(session)
        let earlierIDs = Set(session.recipe.steps.prefix(target).map(\.id))
        session.completedStepIDs = earlierIDs
        session.currentStepIndex = target
        session.timers.removeAll { !earlierIDs.contains($0.associatedStepID) }
        session.acceptedObservations = session.acceptedObservations.filter { entry in
            earlierIDs.contains(String(entry.key.split(separator: "|", maxSplits: 1)[0]))
        }
        session.observationNotBefore = max(session.observationNotBefore, now)
        session.revision += 1
        invalidatePending(&session)
        session.lastAction = "Corrected to step \(target + 1)"
    }

    public func undo(_ session: inout CookingSession, now: Date = Date()) {
        guard let snapshot = session.undoSnapshot else { return }
        let currentManualTimers = session.timers.filter(\.isManual)
        let currentManualByID = Dictionary(uniqueKeysWithValues: currentManualTimers.map { ($0.id, $0) })
        let snapshotIDs = Set(snapshot.timers.map(\.id))
        // Side timers are independent: undoing recipe progress must not erase a newly
        // added timer or rewind a later pause/extension. A correction's removed timers
        // can still be restored from its snapshot.
        let restoredTimers = snapshot.timers.map { timer in
            timer.isManual ? (currentManualByID[timer.id] ?? timer) : timer
        } + currentManualTimers.filter { !snapshotIDs.contains($0.id) }
        guard restoredTimers.filter({ $0.isManual && !$0.isDismissed }).count <= TimerManager.maximumManualTimers else {
            session.lastAction = "Dismiss newer side timers before undoing this correction"
            return
        }
        session.currentStepIndex = snapshot.currentStepIndex
        session.completedStepIDs = snapshot.completedStepIDs
        session.timers = restoredTimers
        session.acceptedObservations = snapshot.acceptedObservations
        session.undoSnapshot = nil
        session.observationNotBefore = max(session.observationNotBefore, now)
        session.revision += 1
        invalidatePending(&session)
        session.lastAction = "Last cooking action undone"
        TimerManager.refresh(in: &session, now: now)
    }

    private func invalidReason(_ observation: CookingObservation, in session: CookingSession,
                               now: Date, checkAge: Bool = true) -> String? {
        guard !session.isFinished else { return "Recipe steps are already complete" }
        guard observation.confidence.isFinite, (0...1).contains(observation.confidence) else {
            return "Invalid confidence"
        }
        guard observation.event != .uncertain && observation.event != .noRelevantEvent else {
            return "No definite cooking action observed"
        }
        let step = session.currentStep
        guard step.expectedEvents.contains(observation.event) else { return "Event is not expected for this step" }
        guard step.prerequisiteStepIDs.isSubset(of: session.completedStepIDs) else {
            return "Required earlier steps are incomplete"
        }
        guard !session.completedStepIDs.contains(step.id),
              session.acceptedObservations[evidenceKey(stepID: step.id, event: observation.event)] == nil else {
            return "This action was already recorded"
        }
        let timestamp = observation.estimatedEventTimestamp
        guard timestamp.timeIntervalSince1970.isFinite,
              timestamp >= session.observationNotBefore,
              timestamp.timeIntervalSince(now) <= futureTolerance else { return "Event timestamp is not valid for this state" }
        if checkAge && now.timeIntervalSince(timestamp) > maximumObservationAge { return "Observation is too old" }
        return nil
    }

    private func perform(_ observation: CookingObservation, in session: inout CookingSession) {
        session.undoSnapshot = SessionSnapshot(session)
        let step = session.currentStep
        recordCompletion(step, observation: observation, in: &session)

        // Waiting on a timer must not hide the upcoming action. If the immediately
        // following action card expects the same event, one observation finishes the
        // waiting phase and that action together (first side → flip → second side).
        let nextIndex = session.currentStepIndex + 1
        if step.optionalTimer != nil, session.recipe.steps.indices.contains(nextIndex) {
            let next = session.recipe.steps[nextIndex]
            if next.optionalTimer == nil, next.allowsAutomaticProgression,
               next.expectedEvents.contains(observation.event),
               next.prerequisiteStepIDs.isSubset(of: session.completedStepIDs) {
                session.currentStepIndex = nextIndex
                recordCompletion(next, observation: observation, in: &session)
            }
        }
        advance(&session, startTimer: true, timerStart: observation.estimatedEventTimestamp)
        session.observationNotBefore = max(session.observationNotBefore, observation.estimatedEventTimestamp)
        session.revision += 1
        invalidatePending(&session)
        switch observation.event {
        case .chickenAddedToPan: session.lastAction = "Chicken added"
        case .chickenFlipped: session.lastAction = "Chicken flipped"
        case .chickenRemovedFromPan: session.lastAction = "Chicken removed — verify 165°F / 74°C"
        default: session.lastAction = "\(step.title) detected"
        }
    }

    private func recordCompletion(_ step: RecipeStep, observation: CookingObservation,
                                  in session: inout CookingSession) {
        session.completedStepIDs.insert(step.id)
        session.acceptedObservations[evidenceKey(stepID: step.id, event: observation.event)] = observation.estimatedEventTimestamp
        TimerManager.complete(stepID: step.id, in: &session)
    }

    private func advance(_ session: inout CookingSession, startTimer: Bool, timerStart: Date) {
        let nextIndex = session.currentStepIndex + 1
        guard session.recipe.steps.indices.contains(nextIndex),
              session.recipe.steps[nextIndex].prerequisiteStepIDs.isSubset(of: session.completedStepIDs) else { return }
        session.currentStepIndex = nextIndex
        if startTimer && !session.completedStepIDs.contains(session.currentStep.id) {
            TimerManager.start(for: session.currentStep, in: &session, now: timerStart)
        }
    }

    private func invalidatePending(_ session: inout CookingSession) {
        session.pendingObservation = nil
        session.pendingRevision = nil
    }

    private func evidenceKey(stepID: String, event: CookingEvent) -> String { "\(stepID)|\(event.rawValue)" }
}
