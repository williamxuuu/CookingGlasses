import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RecipeImportDraft: Codable, Sendable {
    public struct Step: Codable, Identifiable, Sendable {
        public var id = UUID()
        public var title: String
        public var instruction: String
        public var glassesInstruction: String
        public var timerSeconds: Int
        private enum CodingKeys: String, CodingKey { case title, instruction, glassesInstruction, timerSeconds }
    }
    public var title: String
    public var subtitle: String
    public var ingredients: [String]
    public var steps: [Step]
    public var notes: [String]
    public var sourceURL: String?

    public func makeRecipe() throws -> Recipe {
        func valid(_ text: String, _ limit: Int, allowEmpty: Bool = false) -> Bool {
            text.count <= limit && (allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        guard valid(title, 180), valid(subtitle, 300, allowEmpty: true),
              (1...80).contains(ingredients.count), ingredients.allSatisfy({ valid($0, 240) }),
              (1...40).contains(steps.count), steps.allSatisfy({ valid($0.title, 100) && valid($0.instruction, 1600)
                && valid($0.glassesInstruction, 160) && (0...86400).contains($0.timerSeconds) }),
              notes.count <= 12, notes.allSatisfy({ valid($0, 400) }) else {
            throw RecipeImportError.message("Check the recipe: add ingredients and 1–40 complete steps, keep glasses text under 160 characters, and timers between 0 and 24 hours.")
        }
        if let sourceURL {
            guard let url = URL(string: sourceURL), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw RecipeImportError.message("The recipe source link is invalid.") }
        }
        let id = "import-" + UUID().uuidString
        return Recipe(id: id, title: title, subtitle: subtitle, ingredients: ingredients,
            steps: steps.enumerated().map { index, step in
                RecipeStep(id: "\(id)-\(index)", title: step.title, fullInstruction: step.instruction,
                    glassesInstruction: step.glassesInstruction,
                    optionalTimer: step.timerSeconds > 0 ? TimerSpecification(label: step.title, duration: Double(step.timerSeconds)) : nil,
                    prerequisiteStepIDs: index > 0 ? ["\(id)-\(index - 1)"] : [],
                    requiresContinuousAttention: true)
            }, sourceURL: sourceURL, importNotes: notes)
    }
}

public enum RecipeImportError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct RecipeImportService: Sendable {
    public let endpoint: URL
    public let accessToken: String
    public init(backendURL: String, accessToken: String) throws {
        guard var parts = URLComponents(string: backendURL), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil, !accessToken.isEmpty else {
            throw RecipeImportError.message("Add your HTTPS backend address and backend access token in Debug & settings first.")
        }
        // Use the configured server's origin, never follow a URL supplied by a recipe.
        parts.path = "/v1/recipes/import"; parts.query = nil; parts.fragment = nil
        guard let endpoint = parts.url else { throw RecipeImportError.message("The backend address is invalid.") }
        self.endpoint = endpoint; self.accessToken = accessToken
    }
    public func importRecipe(url: String? = nil, jpegData: Data? = nil) async throws -> RecipeImportDraft {
        guard (url != nil) != (jpegData != nil) else { throw RecipeImportError.message("Choose one photo or recipe link.") }
        var body: [String: String] = [:]
        if let url { body["url"] = url }
        if let jpegData { body["jpegBase64"] = jpegData.base64EncodedString() }
        var request = URLRequest(url: endpoint)
        // Video imports have a 90-second backend deadline, plus transport time.
        request.httpMethod = "POST"; request.timeoutInterval = 110
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 128 * 1024, let http = response as? HTTPURLResponse else {
            throw RecipeImportError.message("The import response was invalid.")
        }
        if http.statusCode != 200 {
            if http.statusCode == 401 { throw RecipeImportError.message("Enter the backend access token again in Debug & settings.") }
            struct Failure: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message
            throw RecipeImportError.message(message.map { String($0.prefix(500)) } ?? "Recipe import is unavailable. Check the backend connection and try again.")
        }
        let draft = try JSONDecoder().decode(RecipeImportDraft.self, from: data)
        _ = try draft.makeRecipe()
        return draft
    }
}
