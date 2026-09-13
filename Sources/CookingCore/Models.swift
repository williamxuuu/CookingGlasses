import Foundation

public enum CookingEvent: String, Codable, CaseIterable, Sendable {
    case chickenAddedToPan = "chicken_added_to_pan"
    case chickenFlipped = "chicken_flipped"
    case chickenRemovedFromPan = "chicken_removed_from_pan"
    case potPlacedOnStove = "pot_placed_on_stove"
    case pastaAddedToWater = "pasta_added_to_water"
    case ingredientAdded = "ingredient_added"
    case waterAddedToPot = "water_added_to_pot"
    case waterRollingBoil = "water_rolling_boil"
    case woodenSpoonInserted = "wooden_spoon_inserted"
    case uncertain
    case noRelevantEvent = "no_relevant_event"

    public var confirmationPrompt: String {
        switch self {
        case .chickenAddedToPan: return "Did you just add the chicken to the pan?"
        case .chickenFlipped: return "Did you just flip the chicken?"
        case .chickenRemovedFromPan: return "Did you just remove the chicken from the pan?"
        case .potPlacedOnStove: return "Did you just place the pot on the stove?"
        case .pastaAddedToWater: return "Did you just add pasta to the water?"
        case .ingredientAdded: return "Did you just add the ingredient?"
        case .waterAddedToPot: return "Did you just put water into the pot?"
        case .waterRollingBoil: return "Has the water reached a rolling boil?"
        case .woodenSpoonInserted: return "Did you just put the wooden spoon into the pot?"
        case .uncertain: return "Has the current step happened?"
        case .noRelevantEvent: return "Has the current step happened?"
        }
    }

    public var displayName: String {
        switch self {
        case .waterAddedToPot: return "Water added to pot"
        case .waterRollingBoil: return "Rolling boil detected"
        case .woodenSpoonInserted: return "Wooden spoon inserted"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var watchInstruction: String {
        switch self {
        case .waterAddedToPot: return "Add water to the pot."
        case .waterRollingBoil: return "Wait for a rolling boil."
        case .woodenSpoonInserted: return "Put the wooden spoon in."
        default: return displayName
        }
    }
}

public struct CookingObservation: Codable, Equatable, Sendable {
    public var event: CookingEvent
    public var ingredient: String?
    public var confidence: Double
    public var estimatedEventTimestamp: Date

    public init(event: CookingEvent, ingredient: String? = nil, confidence: Double,
                estimatedEventTimestamp: Date) {
        self.event = event
        self.ingredient = ingredient
        self.confidence = confidence
        self.estimatedEventTimestamp = estimatedEventTimestamp
    }
}

public struct TimerSpecification: Codable, Equatable, Sendable {
    public var label: String
    public var duration: TimeInterval

    public init(label: String, duration: TimeInterval) {
        self.label = label
        self.duration = duration
    }
}

public struct RecipeStep: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var fullInstruction: String
    public var glassesInstruction: String
    public var expectedEvents: Set<CookingEvent>
    public var optionalTimer: TimerSpecification?
    public var prerequisiteStepIDs: Set<String>
    public var requiresContinuousAttention: Bool
    public var allowsAutomaticProgression: Bool
    /// Optional ordered checkpoints within one recipe step. Missing in older saved recipes.
    public var requiredEventSequence: [CookingEvent]?

    public init(id: String, title: String, fullInstruction: String, glassesInstruction: String,
                expectedEvents: Set<CookingEvent> = [], optionalTimer: TimerSpecification? = nil,
                prerequisiteStepIDs: Set<String> = [], requiresContinuousAttention: Bool = false,
                allowsAutomaticProgression: Bool = false, requiredEventSequence: [CookingEvent]? = nil) {
        self.id = id
        self.title = title
        self.fullInstruction = fullInstruction
        self.glassesInstruction = glassesInstruction
        self.expectedEvents = expectedEvents
        self.optionalTimer = optionalTimer
        self.prerequisiteStepIDs = prerequisiteStepIDs
        self.requiresContinuousAttention = requiresContinuousAttention
        self.allowsAutomaticProgression = allowsAutomaticProgression
        self.requiredEventSequence = requiredEventSequence
    }
}

public struct Recipe: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var ingredients: [String]
    public var steps: [RecipeStep]
    public var sourceURL: String?
    public var importNotes: [String]?

    public init(id: String, title: String, subtitle: String, ingredients: [String], steps: [RecipeStep], sourceURL: String? = nil, importNotes: [String]? = nil) {
        precondition(!steps.isEmpty, "A recipe requires at least one step")
        precondition(Set(steps.map(\.id)).count == steps.count, "Step IDs must be unique")
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.ingredients = ingredients
        self.steps = steps
        self.sourceURL = sourceURL
        self.importNotes = importNotes
    }
}

public struct CookingTimer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var associatedStepID: String
    public var startTime: Date
    public var duration: TimeInterval
    public var targetEndTime: Date
    public var isPaused: Bool
    public var isCompleted: Bool
    public var isDismissed: Bool
    /// User-created side timers do not complete when the associated recipe step completes.
    public var isManual: Bool
    /// Frozen remaining time is persisted so pausing survives process termination.
    public internal(set) var pausedRemaining: TimeInterval?

    public init(id: UUID = UUID(), label: String, associatedStepID: String, startTime: Date,
                duration: TimeInterval, targetEndTime: Date? = nil, isPaused: Bool = false,
                isCompleted: Bool = false, isDismissed: Bool = false, isManual: Bool = false,
                pausedRemaining: TimeInterval? = nil) {
        self.id = id
        self.label = label
        self.associatedStepID = associatedStepID
        self.startTime = startTime
        self.duration = max(0, duration)
        self.targetEndTime = targetEndTime ?? startTime.addingTimeInterval(max(0, duration))
        self.isPaused = isPaused
        self.isCompleted = isCompleted
        self.isDismissed = isDismissed
        self.isManual = isManual
        self.pausedRemaining = isPaused ? (pausedRemaining ?? max(0, duration)) : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, associatedStepID, startTime, duration, targetEndTime
        case isPaused, isCompleted, isDismissed, isManual, pausedRemaining
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        label = try values.decode(String.self, forKey: .label)
        associatedStepID = try values.decode(String.self, forKey: .associatedStepID)
        startTime = try values.decode(Date.self, forKey: .startTime)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        targetEndTime = try values.decode(Date.self, forKey: .targetEndTime)
        isPaused = try values.decode(Bool.self, forKey: .isPaused)
        isCompleted = try values.decode(Bool.self, forKey: .isCompleted)
        isDismissed = try values.decodeIfPresent(Bool.self, forKey: .isDismissed) ?? false
        // Sessions saved before side timers existed remain recipe timers.
        isManual = try values.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        pausedRemaining = try values.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
    }

    public func remaining(at now: Date) -> TimeInterval {
        if isCompleted { return 0 }
        return max(0, isPaused ? (pausedRemaining ?? 0) : targetEndTime.timeIntervalSince(now))
    }

    public func isExpired(at now: Date) -> Bool {
        !isDismissed && !isPaused && (isCompleted || targetEndTime <= now)
    }
}

public struct CookingSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var recipe: Recipe
    public var currentStepIndex: Int
    public var completedStepIDs: Set<String>
    public var timers: [CookingTimer]
    public var revision: Int
    public var pendingObservation: CookingObservation?
    public var lastAction: String?
    public private(set) var startedAt: Date
    var observationNotBefore: Date
    var acceptedObservations: [String: Date]
    var pendingRevision: Int?
    var undoSnapshot: SessionSnapshot?

    public init(recipe: Recipe, now: Date = Date()) {
        id = UUID()
        self.recipe = recipe
        currentStepIndex = 0
        completedStepIDs = []
        timers = []
        revision = 0
        pendingObservation = nil
        lastAction = nil
        startedAt = now
        observationNotBefore = now
        acceptedObservations = [:]
    }

    public var currentStep: RecipeStep {
        recipe.steps[min(max(currentStepIndex, 0), recipe.steps.count - 1)]
    }

    public var isFinished: Bool {
        recipe.steps.allSatisfy { completedStepIDs.contains($0.id) }
    }

    public var canUndo: Bool { undoSnapshot != nil }

    public func observedAt(_ event: CookingEvent, stepID: String? = nil) -> Date? {
        acceptedObservations["\(stepID ?? currentStep.id)|\(event.rawValue)"]
    }

    public var expectedEvents: Set<CookingEvent> {
        guard !completedStepIDs.contains(currentStep.id) else { return [] }
        if let sequence = currentStep.requiredEventSequence, !sequence.isEmpty {
            guard let next = sequence.first(where: { observedAt($0) == nil }) else { return [] }
            return [next]
        }
        return currentStep.expectedEvents
    }

    /// Send only the next checkpoint to vision while preserving the single-step recipe.
    public var visionStep: RecipeStep {
        var step = currentStep
        step.expectedEvents = expectedEvents
        if let sequence = step.requiredEventSequence, !sequence.isEmpty, let next = expectedEvents.first {
            step.fullInstruction += " Current checkpoint: \(next.watchInstruction) Report only this checkpoint when visibly supported. Earlier checkpoints are already recorded."
        }
        return step
    }
}

/// A single nonrecursive snapshot includes timer deadlines, preserving exact undo semantics.
struct SessionSnapshot: Codable, Equatable, Sendable {
    var currentStepIndex: Int
    var completedStepIDs: Set<String>
    var timers: [CookingTimer]
    var acceptedObservations: [String: Date]
    var lastAction: String?

    init(_ session: CookingSession) {
        currentStepIndex = session.currentStepIndex
        completedStepIDs = session.completedStepIDs
        timers = session.timers
        acceptedObservations = session.acceptedObservations
        lastAction = session.lastAction
    }
}
