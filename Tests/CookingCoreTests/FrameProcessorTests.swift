import XCTest
@testable import CookingCore

final class FrameProcessorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func frame(_ value: UInt8, at offset: TimeInterval) -> CameraFrame {
        CameraFrame(timestamp: now.addingTimeInterval(offset), jpegData: Data([0xff, 0xd8, value, 0xff, 0xd9]),
                    luminance: Array(repeating: value, count: 32 * 32))
    }

    func testStaticScenesNeverUploadEvenWhenActionExpected() {
        var processor = FrameProcessor()
        for second in 0...20 {
            XCTAssertNil(processor.receive(frame(100, at: Double(second)), expectsAction: true, timerWaiting: false))
        }
        XCTAssertEqual(processor.changeScore, 0)
        XCTAssertNil(processor.lastRequestTimestamp)
        XCTAssertLessThanOrEqual(processor.frames.count, 8)
    }

    func testMeaningfulChangeRequiresTwoFramesAndExpectedAction() {
        var processor = FrameProcessor()
        XCTAssertNil(processor.receive(frame(0, at: 0), expectsAction: false, timerWaiting: false))
        XCTAssertNil(processor.receive(frame(255, at: 1), expectsAction: false, timerWaiting: false))
        XCTAssertEqual(processor.changeScore, 1)
        XCTAssertNil(processor.lastRequestTimestamp)
        processor.reset()
        XCTAssertNil(processor.receive(frame(0, at: 2), expectsAction: true, timerWaiting: false))
        let sequence = processor.receive(frame(255, at: 2.5), expectsAction: true, timerWaiting: false)
        XCTAssertEqual(sequence?.count, 2)
        XCTAssertEqual(sequence?.first?.timestamp, now.addingTimeInterval(2))
        XCTAssertEqual(sequence?.last?.timestamp, now.addingTimeInterval(2.5))
    }

    func testCooldownAndInFlightGatePreventDuplicateRequests() {
        var processor = FrameProcessor()
        _ = processor.receive(frame(0, at: 0), expectsAction: true, timerWaiting: false)
        XCTAssertNotNil(processor.receive(frame(255, at: 1), expectsAction: true, timerWaiting: false))
        for second in 2...10 {
            XCTAssertNil(processor.receive(frame(second.isMultiple(of: 2) ? 0 : 255, at: Double(second)),
                                           expectsAction: true, timerWaiting: false))
        }
        processor.finishRequest()
        XCTAssertTrue(processor.frames.isEmpty)
        XCTAssertNil(processor.receive(frame(255, at: 11), expectsAction: true, timerWaiting: false))
        XCTAssertNotNil(processor.receive(frame(0, at: 12), expectsAction: true, timerWaiting: false))
        processor.finishRequest()
        XCTAssertNil(processor.receive(frame(255, at: 13), expectsAction: true, timerWaiting: false))
        XCTAssertNil(processor.receive(frame(0, at: 14), expectsAction: true, timerWaiting: false))
        XCTAssertNil(processor.receive(frame(0, at: 19), expectsAction: true, timerWaiting: false))
        XCTAssertNotNil(processor.receive(frame(255, at: 20), expectsAction: true, timerWaiting: false))
    }

    func testBufferRetiresFramesAfterFiveSecondsAndNeverExceedsEight() {
        var processor = FrameProcessor()
        for index in 0...30 {
            _ = processor.receive(frame(100, at: Double(index) * 0.5), expectsAction: true, timerWaiting: false)
            XCTAssertLessThanOrEqual(processor.frames.count, 8)
            XCTAssertTrue(processor.frames.allSatisfy { Double(index) * 0.5 - $0.timestamp.timeIntervalSince(now) <= 5 })
        }
        _ = processor.receive(frame(100, at: 100), expectsAction: true, timerWaiting: false)
        XCTAssertEqual(processor.frames.count, 1)
        XCTAssertEqual(processor.frames[0].timestamp, now.addingTimeInterval(100))
    }

    func testTimerWaitingSamplesAtReducedRateAndNeedsRelevantAction() {
        var processor = FrameProcessor()
        XCTAssertNil(processor.receive(frame(0, at: 0), expectsAction: true, timerWaiting: true))
        XCTAssertNil(processor.receive(frame(255, at: 0.5), expectsAction: true, timerWaiting: true))
        XCTAssertNil(processor.receive(frame(255, at: 2.9), expectsAction: true, timerWaiting: true))
        XCTAssertEqual(processor.frames.count, 1)
        XCTAssertNotNil(processor.receive(frame(255, at: 3), expectsAction: true, timerWaiting: true))
        processor.reset()
        _ = processor.receive(frame(0, at: 0), expectsAction: false, timerWaiting: true)
        XCTAssertNil(processor.receive(frame(255, at: 3), expectsAction: false, timerWaiting: true))
        XCTAssertEqual(processor.frames.count, 2)
        XCTAssertNil(processor.lastRequestTimestamp)
    }

    func testNormalAndExpectedActionSamplingRatesDiffer() {
        var processor = FrameProcessor()
        _ = processor.receive(frame(0, at: 0), expectsAction: false, timerWaiting: false)
        _ = processor.receive(frame(255, at: 0.5), expectsAction: false, timerWaiting: false)
        XCTAssertEqual(processor.frames.count, 1)
        _ = processor.receive(frame(255, at: 1), expectsAction: false, timerWaiting: false)
        XCTAssertEqual(processor.frames.count, 2)
        processor.reset()
        _ = processor.receive(frame(0, at: 0), expectsAction: true, timerWaiting: false)
        XCTAssertNotNil(processor.receive(frame(255, at: 0.5), expectsAction: true, timerWaiting: false))
    }

    func testFinishDiscardsJPEGSequencesAndResetDropsAnalysisHistory() {
        var processor = FrameProcessor()
        _ = processor.receive(frame(0, at: 0), expectsAction: true, timerWaiting: false)
        _ = processor.receive(frame(255, at: 1), expectsAction: true, timerWaiting: false)
        processor.finishRequest()
        XCTAssertTrue(processor.frames.isEmpty)
        XCTAssertEqual(processor.lastRequestTimestamp, now.addingTimeInterval(1))
        processor.reset()
        XCTAssertTrue(processor.frames.isEmpty)
        XCTAssertNil(processor.lastRequestTimestamp)
        XCTAssertEqual(processor.changeScore, 0)
        XCTAssertNil(processor.receive(frame(0, at: 1.5), expectsAction: true, timerWaiting: false))
        XCTAssertNotNil(processor.receive(frame(255, at: 2), expectsAction: true, timerWaiting: false))
    }

    func testMalformedFramesAndNonmonotonicTimestampsAreRejected() {
        var processor = FrameProcessor()
        let malformed = [
            CameraFrame(timestamp: now, jpegData: Data(), luminance: Array(repeating: 0, count: 1024)),
            CameraFrame(timestamp: now, jpegData: Data([1]), luminance: []),
            CameraFrame(timestamp: now, jpegData: Data([1]), luminance: Array(repeating: 0, count: 1023)),
            CameraFrame(timestamp: now, jpegData: Data(repeating: 0, count: 512 * 1024 + 1), luminance: Array(repeating: 0, count: 1024)),
            CameraFrame(timestamp: Date(timeIntervalSince1970: .nan), jpegData: Data([1]), luminance: Array(repeating: 0, count: 1024)),
            CameraFrame(timestamp: Date(timeIntervalSince1970: .infinity), jpegData: Data([1]), luminance: Array(repeating: 0, count: 1024))
        ]
        for candidate in malformed {
            XCTAssertNil(processor.receive(candidate, expectsAction: true, timerWaiting: false))
            XCTAssertTrue(processor.frames.isEmpty)
        }
        _ = processor.receive(frame(0, at: 10), expectsAction: true, timerWaiting: false)
        XCTAssertNil(processor.receive(frame(255, at: 9), expectsAction: true, timerWaiting: false))
        XCTAssertEqual(processor.frames.count, 1)
        XCTAssertEqual(processor.changeScore, 0)
    }

    func testConfigurationCannotRemoveMemoryBoundsOrTrapOnInvalidCapacity() {
        var configuration = FrameProcessor.Configuration()
        configuration.maxFrames = -5
        configuration.bufferDuration = .infinity
        configuration.expectedActionInterval = .nan
        configuration.changeThreshold = .nan
        configuration.requestCooldown = .infinity
        var processor = FrameProcessor(configuration: configuration)
        for second in 0...20 {
            XCTAssertNil(processor.receive(frame(100, at: Double(second)), expectsAction: true, timerWaiting: false))
            XCTAssertLessThanOrEqual(processor.frames.count, 2)
            XCTAssertTrue(processor.frames.allSatisfy { Double(second) - $0.timestamp.timeIntervalSince(now) <= 5 })
        }
        configuration.maxFrames = 1_000
        configuration.bufferDuration = 1_000
        configuration.expectedActionInterval = 0.1
        processor = FrameProcessor(configuration: configuration)
        for index in 0...100 {
            _ = processor.receive(frame(100, at: Double(index) * 0.1), expectsAction: true, timerWaiting: false)
            XCTAssertLessThanOrEqual(processor.frames.count, 8)
        }
    }
}
