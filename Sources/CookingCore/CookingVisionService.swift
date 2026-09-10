import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CookingVisionRequest: Encodable, Sendable {
    public struct RecipeContext: Encodable, Sendable { public let id: String; public let title: String }
    public struct StepContext: Encodable, Sendable { public let id: String; public let title: String; public let fullInstruction: String }
    public struct Frame: Encodable, Sendable { public let timestamp: Double; public let jpegBase64: String }
    public let recipe: RecipeContext
    public let step: StepContext
    public let expectedEvents: [String]
    public let frames: [Frame]
    public init(recipe: Recipe, step: RecipeStep, frames: [CameraFrame]) {
        self.recipe = .init(id: recipe.id, title: recipe.title)
        self.step = .init(id: step.id, title: step.title, fullInstruction: step.fullInstruction)
        expectedEvents = step.expectedEvents.map(\.rawValue).sorted()
        self.frames = frames.map { .init(timestamp: $0.timestamp.timeIntervalSince1970, jpegBase64: $0.jpegData.base64EncodedString()) }
    }
}

public protocol CookingVisionService: Sendable {
    func observe(_ request: CookingVisionRequest) async throws -> CookingObservation
}

public struct GeminiCookingVisionService: CookingVisionService {
    public let endpoint: URL
    public let accessToken: String
    public init(endpoint: URL, accessToken: String) { self.endpoint = endpoint; self.accessToken = accessToken }
    public func observe(_ input: CookingVisionRequest) async throws -> CookingObservation {
        guard endpoint.scheme == "https" else { throw VisionError.httpsRequired }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(input)
        // Ephemeral transport: no URL cache or persistent cookies for camera requests.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 16_384 else { throw VisionError.invalidResponse }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let observation = try decoder.decode(CookingObservation.self, from: data)
        guard observation.confidence.isFinite, (0...1).contains(observation.confidence),
              let start = input.frames.first?.timestamp, let end = input.frames.last?.timestamp,
              (start...end).contains(observation.estimatedEventTimestamp.timeIntervalSince1970) else { throw VisionError.invalidResponse }
        return observation
    }
    public enum VisionError: LocalizedError {
        case httpsRequired, invalidResponse
        public var errorDescription: String? {
            switch self {
            case .httpsRequired: return "Enter an HTTPS backend endpoint."
            case .invalidResponse: return "Vision service returned an invalid response. Try again or use manual controls."
            }
        }
    }
}

public struct MockCookingVisionService: CookingVisionService {
    public init() {}
    public func observe(_ request: CookingVisionRequest) async throws -> CookingObservation {
        CookingObservation(event: .noRelevantEvent, confidence: 1, estimatedEventTimestamp: Date(timeIntervalSince1970: request.frames.last?.timestamp ?? Date().timeIntervalSince1970))
    }
}
