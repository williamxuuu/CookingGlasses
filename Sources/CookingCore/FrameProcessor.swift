import Foundation

public struct CameraFrame: Sendable {
    public let timestamp: Date
    public let jpegData: Data
    public let luminance: [UInt8]
    public init(timestamp: Date, jpegData: Data, luminance: [UInt8]) {
        self.timestamp = timestamp; self.jpegData = jpegData; self.luminance = luminance
    }
}

/// Bounded, memory-only event gate. No frames are written to session persistence.
public struct FrameProcessor {
    public struct Configuration: Sendable {
        public var normalInterval: TimeInterval = 1
        public var expectedActionInterval: TimeInterval = 0.5
        public var timerWaitingInterval: TimeInterval = 3
        public var requestCooldown: TimeInterval = 8
        public var bufferDuration: TimeInterval = 5
        public var changeThreshold: Double = 0.075
        public var maxFrames = 8
        public init() {}
    }
    public var configuration: Configuration
    public private(set) var changeScore: Double = 0
    public private(set) var lastRequestTimestamp: Date?
    public private(set) var frames: [CameraFrame] = []
    private var previousLuminance: [UInt8]?
    private var lastSample: Date?
    private var firstSample: Date?
    private var requestInFlight = false
    public init(configuration: Configuration = .init()) { self.configuration = configuration }

    public mutating func receive(_ frame: CameraFrame, expectsAction: Bool, timerWaiting: Bool,
                                 periodicCheckInterval: TimeInterval? = nil) -> [CameraFrame]? {
        guard frame.timestamp.timeIntervalSince1970.isFinite, frame.luminance.count == 32 * 32,
              !frame.jpegData.isEmpty, frame.jpegData.count <= 512 * 1024 else { return nil }
        let retention = configuration.bufferDuration.isFinite ? min(5, max(0.5, configuration.bufferDuration)) : 5
        let capacity = min(8, max(2, configuration.maxFrames))
        // Retire old pixels even when sampling is throttled or the scene stays static.
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > retention }
        let configuredInterval = timerWaiting ? configuration.timerWaitingInterval : (expectsAction ? configuration.expectedActionInterval : configuration.normalInterval)
        let interval = configuredInterval.isFinite ? max(0.1, configuredInterval) : 1
        if let lastSample, frame.timestamp.timeIntervalSince(lastSample) < interval { return nil }
        lastSample = frame.timestamp
        if firstSample == nil { firstSample = frame.timestamp }
        if let previous = previousLuminance, previous.count == frame.luminance.count {
            let total = zip(previous, frame.luminance).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            changeScore = total / Double(previous.count) / 255
        } else { changeScore = 0 }
        previousLuminance = frame.luminance
        frames.append(frame)
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        let threshold = configuration.changeThreshold.isFinite ? min(1, max(0, configuration.changeThreshold)) : 0.075
        // Some visual states (like a rolling boil) change too little in a 32x32
        // image to trigger the motion gate. Explicitly opted-in steps get a fallback.
        let periodicDue = periodicCheckInterval.map { interval in
            interval.isFinite && interval > 0 && frame.timestamp.timeIntervalSince(lastRequestTimestamp ?? firstSample ?? frame.timestamp) >= interval
        } ?? false
        guard expectsAction, !requestInFlight, frames.count >= 2,
              changeScore >= threshold || periodicDue else { return nil }
        let cooldown = configuration.requestCooldown.isFinite ? max(0, configuration.requestCooldown) : 8
        if let lastRequestTimestamp, frame.timestamp.timeIntervalSince(lastRequestTimestamp) < cooldown { return nil }
        requestInFlight = true
        lastRequestTimestamp = frame.timestamp
        return frames
    }
    public mutating func finishRequest() { requestInFlight = false; frames.removeAll() }
    public mutating func reset() {
        frames.removeAll(); previousLuminance = nil; lastSample = nil; firstSample = nil
        requestInFlight = false; changeScore = 0; lastRequestTimestamp = nil
    }
}
