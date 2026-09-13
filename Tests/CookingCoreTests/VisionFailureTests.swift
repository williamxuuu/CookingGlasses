import XCTest
@testable import CookingCore

final class VisionFailureTests: XCTestCase {
    func testServiceFailuresAreDistinctAndDoNotEchoRemoteMessages() {
        let service = GeminiCookingVisionService.self
        XCTAssertTrue(service.failureDescription(service.VisionError.service(status: 504, code: "model_timeout")).contains("Gemini timed out"))
        XCTAssertTrue(service.failureDescription(service.VisionError.service(status: 401, code: "unauthorized")).contains("access denied"))
        XCTAssertTrue(service.failureDescription(service.VisionError.service(status: 530, code: "secret server text")).contains("tunnel"))
        XCTAssertFalse(service.failureDescription(service.VisionError.service(status: 500, code: "secret server text")).contains("secret"))
        XCTAssertTrue(service.failureDescription(URLError(.networkConnectionLost)).contains("Connection dropped"))
    }

    func testLowConfidenceAndUncertainAreSuccessfulResponses() throws {
        let recipe = SampleRecipes.waterBoilSpoonTest
        let frame = CameraFrame(timestamp: Date(timeIntervalSince1970: 100), jpegData: Data(), luminance: [0])
        let input = CookingVisionRequest(recipe: recipe, step: recipe.steps[0], frames: [frame])
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        for event in [CookingEvent.waterAddedToPot, .uncertain] {
            let observation = CookingObservation(event: event, confidence: 0.6, estimatedEventTimestamp: frame.timestamp)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let decoded = try GeminiCookingVisionService.decodeResponse(encoder.encode(observation), response: response, input: input)
            XCTAssertEqual(decoded.confidence, 0.6)
            XCTAssertEqual(decoded.event, event)
        }
    }
}
