import Foundation
import CookingCore

struct GlassesViewModel: Equatable {
    var stepNumber: Int
    var totalSteps: Int
    var instruction: String
    var timerLabel: String?
    var timerRemaining: TimeInterval?
    var additionalTimerCount: Int
    var watchActive: Bool
    var notice: String?
    var expiredTimerID: UUID?
    var canUndo: Bool

    static func make(session: CookingSession, watchActive: Bool, now: Date) -> Self {
        let timers = session.timers.filter { !$0.isDismissed && (!$0.isCompleted || $0.isExpired(at: now)) }
            .sorted { $0.targetEndTime < $1.targetEndTime }
        let nearest = timers.first(where: { $0.isExpired(at: now) }) ?? timers.first(where: { !$0.isPaused }) ?? timers.first
        return .init(stepNumber: session.currentStepIndex + 1, totalSteps: session.recipe.steps.count,
                     instruction: session.currentStep.requiredEventSequence?.isEmpty == false
                        ? (session.isFinished ? "Test step complete." : session.expectedEvents.first?.watchInstruction ?? session.currentStep.glassesInstruction)
                        : session.currentStep.glassesInstruction,
                     timerLabel: nearest?.label, timerRemaining: nearest?.remaining(at: now),
                     additionalTimerCount: max(0, timers.count - 1), watchActive: watchActive,
                     notice: session.lastAction, expiredTimerID: nearest.flatMap { $0.isExpired(at: now) ? $0.id : nil },
                     canUndo: session.canUndo)
    }
}

func timerText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(ceil(interval)))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
