import Foundation

public struct SessionPersistence: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> CookingSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let session = try JSONDecoder().decode(CookingSession.self, from: Data(contentsOf: url))
        try validate(session)
        return session
    }

    public func save(_ session: CookingSession) throws {
        try validate(session)
        let data = try JSONEncoder().encode(session)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: url.path)
        #endif
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func validate(_ session: CookingSession) throws {
        let steps = session.recipe.steps
        let IDs = Set(steps.map(\.id))
        let recipeTimers = session.timers.filter { !$0.isManual }
        guard !steps.isEmpty, IDs.count == steps.count, steps.indices.contains(session.currentStepIndex),
              session.completedStepIDs.isSubset(of: IDs), session.revision >= 0,
              Set(session.timers.map(\.id)).count == session.timers.count,
              Set(recipeTimers.map(\.associatedStepID)).count == recipeTimers.count,
              session.timers.filter({ $0.isManual && !$0.isDismissed }).count <= TimerManager.maximumManualTimers else {
            throw PersistenceError.invalidSession
        }
        for (index, step) in steps.enumerated() {
            guard step.prerequisiteStepIDs.isSubset(of: Set(steps.prefix(index).map(\.id))) else {
                throw PersistenceError.invalidSession
            }
        }
        for timer in session.timers {
            guard IDs.contains(timer.associatedStepID), timer.duration.isFinite, timer.duration >= 0,
                  timer.startTime.timeIntervalSince1970.isFinite, timer.targetEndTime.timeIntervalSince1970.isFinite,
                  !timer.isPaused || (timer.pausedRemaining?.isFinite == true && (timer.pausedRemaining ?? -1) >= 0) else {
                throw PersistenceError.invalidSession
            }
            if timer.isManual {
                guard !timer.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      timer.label.count <= TimerManager.maximumManualLabelLength,
                      timer.duration > 0, timer.duration <= TimerManager.maximumManualDuration else {
                    throw PersistenceError.invalidSession
                }
            }
        }
    }

    public enum PersistenceError: LocalizedError {
        case invalidSession
        public var errorDescription: String? { "The saved cooking session is invalid and could not be restored." }
    }
}
