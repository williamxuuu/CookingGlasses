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
        return try Self.decodeResponse(data, response: response, input: input)
    }

    static func decodeResponse(_ data: Data, response: URLResponse, input: CookingVisionRequest) throws -> CookingObservation {
        guard let http = response as? HTTPURLResponse else { throw VisionError.invalidResponse }
        guard http.statusCode == 200 else {
            let code = data.count < 16_384 ? (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code : nil
            throw VisionError.service(status: http.statusCode, code: code)
        }
        guard data.count < 16_384 else { throw VisionError.invalidResponse }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard let observation = try? decoder.decode(CookingObservation.self, from: data) else { throw VisionError.invalidResponse }
        guard observation.confidence.isFinite, (0...1).contains(observation.confidence),
              let start = input.frames.first?.timestamp, let end = input.frames.last?.timestamp,
              (start...end).contains(observation.estimatedEventTimestamp.timeIntervalSince1970) else { throw VisionError.invalidResponse }
        return observation
    }
    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }

    public static func failureDescription(_ error: Error) -> String {
        if let error = error as? VisionError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "Connection timed out. Watch will retry."
            case .notConnectedToInternet: return "Phone is offline. Check its internet connection."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "Cannot reach the backend. Check the tunnel and endpoint."
            case .networkConnectionLost: return "Connection dropped during the vision request. Watch will retry."
            default: return "Vision connection failed (network code \(error.code.rawValue))."
            }
        }
        return "Vision request failed. Check backend diagnostics."
    }

    public enum VisionError: LocalizedError {
        case service(status: Int, code: String?)
        case httpsRequired, invalidResponse
        public var errorDescription: String? {
            switch self {
            case let .service(status, code):
                switch code {
                case "model_timeout": return "Gemini timed out. Watch will retry."
                case "model_rate_limited": return "Gemini rate limit reached. Watch will retry."
                case "model_overloaded": return "Gemini is overloaded. Watch will retry."
                case "model_unavailable": return "Gemini is unavailable. Watch will retry."
                case "invalid_model_response": return "Gemini returned an invalid observation. Watch will retry."
                case "invalid_request": return "Backend rejected the camera request. Check backend diagnostics."
                default:
                    switch status {
                    case 401, 403: return "Backend access denied. Check the access token."
                    case 429: return "Backend is busy or rate limited. Watch will retry."
                    case 502, 503, 504, 530: return "Backend or tunnel unavailable (HTTP \(status)). Watch will retry."
                    default: return "Vision request failed (HTTP \(status))."
                    }
                }
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
