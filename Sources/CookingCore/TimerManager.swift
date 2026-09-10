import Foundation

public enum TimerManager {
    public static let maximumManualTimers = 8
    public static let maximumManualDuration: TimeInterval = 86_400
    public static let maximumManualLabelLength = 50

    /// A dismissed or completed timer still counts; looking back cannot restart it.
    public static func start(for step: RecipeStep, in session: inout CookingSession, now: Date = Date()) {
        guard let specification = step.optionalTimer,
              specification.duration.isFinite, specification.duration > 0,
              !session.timers.contains(where: { !$0.isManual && $0.associatedStepID == step.id }) else { return }
        session.timers.append(CookingTimer(label: specification.label, associatedStepID: step.id,
                                          startTime: now, duration: specification.duration))
    }

    /// Up to eight undismissed side timers can run alongside recipe timers. Finished
    /// reminders keep a slot until dismissed so the active list stays bounded.
    @discardableResult
    public static func startManual(label: String, duration: TimeInterval, in session: inout CookingSession,
                                   now: Date = Date()) -> Bool {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty, trimmedLabel.count <= maximumManualLabelLength,
              duration.isFinite, duration > 0, duration <= maximumManualDuration,
              now.timeIntervalSince1970.isFinite,
              session.timers.filter({ $0.isManual && !$0.isDismissed }).count < maximumManualTimers else {
            return false
        }
        session.timers.append(CookingTimer(label: trimmedLabel, associatedStepID: session.currentStep.id,
                                          startTime: now, duration: duration, isManual: true))
        return true
    }

    public static func pause(id: UUID, in session: inout CookingSession, now: Date = Date()) {
        guard let index = session.timers.firstIndex(where: { $0.id == id }),
              !session.timers[index].isPaused, !session.timers[index].isCompleted,
              !session.timers[index].isDismissed, !session.timers[index].isExpired(at: now) else { return }
        session.timers[index].pausedRemaining = session.timers[index].remaining(at: now)
        session.timers[index].isPaused = true
    }

    public static func resume(id: UUID, in session: inout CookingSession, now: Date = Date()) {
        guard let index = session.timers.firstIndex(where: { $0.id == id }),
              session.timers[index].isPaused, !session.timers[index].isDismissed else { return }
        session.timers[index].targetEndTime = now.addingTimeInterval(session.timers[index].pausedRemaining ?? 0)
        session.timers[index].pausedRemaining = nil
        session.timers[index].isPaused = false
    }

    public static func dismiss(id: UUID, in session: inout CookingSession) {
        guard let index = session.timers.firstIndex(where: { $0.id == id }) else { return }
        session.timers[index].isDismissed = true
    }

    public static func extend(id: UUID, in session: inout CookingSession, by seconds: TimeInterval,
                              now: Date = Date()) {
        guard seconds.isFinite, seconds > 0,
              let index = session.timers.firstIndex(where: { $0.id == id }) else { return }
        let remaining = session.timers[index].remaining(at: now) + seconds
        let duration = session.timers[index].duration + seconds
        guard remaining.isFinite, duration.isFinite else { return }
        if session.timers[index].isManual {
            guard duration <= maximumManualDuration else { return }
            if session.timers[index].isDismissed,
               session.timers.filter({ $0.isManual && !$0.isDismissed }).count >= maximumManualTimers { return }
        }
        session.timers[index].duration = duration
        session.timers[index].targetEndTime = now.addingTimeInterval(remaining)
        session.timers[index].isCompleted = false
        session.timers[index].isDismissed = false
        if session.timers[index].isPaused { session.timers[index].pausedRemaining = remaining }
    }

    /// Expiry changes timer presentation only. It never completes a recipe step or declares food safe.
    public static func refresh(in session: inout CookingSession, now: Date = Date()) {
        for index in session.timers.indices where session.timers[index].isExpired(at: now) {
            session.timers[index].isCompleted = true
        }
    }

    static func complete(stepID: String, in session: inout CookingSession) {
        for index in session.timers.indices where !session.timers[index].isManual && session.timers[index].associatedStepID == stepID {
            session.timers[index].isCompleted = true
            session.timers[index].isDismissed = true
            session.timers[index].isPaused = false
            session.timers[index].pausedRemaining = nil
        }
    }
}
