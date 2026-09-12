import XCTest
@testable import CookingCore

final class RecipeImportTests: XCTestCase {
    private func draft() throws -> RecipeImportDraft {
        let data = Data(#"{"title":"Yogurt dip","subtitle":"Serves 2","ingredients":["200 g yogurt","1 tsp lemon juice"],"steps":[{"title":"Combine","instruction":"Stir yogurt and lemon together.","glassesInstruction":"Stir yogurt + lemon.","timerSeconds":0},{"title":"Chill","instruction":"Chill for 5 minutes.","glassesInstruction":"Chill 5 minutes.","timerSeconds":300}],"notes":[],"sourceURL":"https://example.com/dip"}"#.utf8)
        return try JSONDecoder().decode(RecipeImportDraft.self, from: data)
    }
    func testImportKeepsQuantitiesTimersAndSourceWithUniqueOrderedSteps() throws {
        let recipe = try draft().makeRecipe()
        XCTAssertEqual(recipe.ingredients, ["200 g yogurt", "1 tsp lemon juice"])
        XCTAssertEqual(recipe.sourceURL, "https://example.com/dip")
        XCTAssertNil(recipe.steps[0].optionalTimer)
        XCTAssertEqual(recipe.steps[1].optionalTimer?.duration, 300)
        XCTAssertEqual(recipe.steps[1].prerequisiteStepIDs, [recipe.steps[0].id])
        XCTAssertTrue(recipe.steps.allSatisfy { $0.expectedEvents.isEmpty && !$0.allowsAutomaticProgression })
        XCTAssertEqual(Set(recipe.steps.map(\.id)).count, 2)
    }
    func testEditsAndReorderingBecomeCookingOrder() throws {
        var value = try draft()
        value.title = "My dip"; value.steps.reverse(); value.steps[0].timerSeconds = 120
        let recipe = try value.makeRecipe()
        XCTAssertEqual(recipe.title, "My dip")
        XCTAssertEqual(recipe.steps[0].title, "Chill")
        XCTAssertEqual(recipe.steps[0].optionalTimer?.duration, 120)
        XCTAssertTrue(recipe.steps[0].prerequisiteStepIDs.isEmpty)
    }
    func testYouTubeDraftKeepsSourceReviewNotesAndGlassesInstructionsWhenSaved() throws {
        var value = try draft()
        value.sourceURL = "https://www.youtube.com/watch?v=AbCdEf12_-3"
        value.notes = ["The video does not state the oil quantity."]
        let recipe = try value.makeRecipe()
        let saved = try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(saved.sourceURL, value.sourceURL)
        XCTAssertEqual(saved.importNotes, value.notes)
        XCTAssertEqual(saved.steps.map(\.glassesInstruction), value.steps.map(\.glassesInstruction))
        XCTAssertEqual(saved.steps[1].optionalTimer?.duration, 300)
        XCTAssertTrue(saved.steps.allSatisfy { !$0.allowsAutomaticProgression })
    }
    func testInvalidDraftCannotConstructRecipe() throws {
        var value = try draft(); value.steps = []
        XCTAssertThrowsError(try value.makeRecipe())
        value = try draft(); value.steps[0].timerSeconds = -1
        XCTAssertThrowsError(try value.makeRecipe())
        value = try draft(); value.ingredients = [" "]
        XCTAssertThrowsError(try value.makeRecipe())
        value = try draft(); value.steps[0].glassesInstruction = String(repeating: "x", count: 161)
        XCTAssertThrowsError(try value.makeRecipe())
    }
    func testImportedRecipeAndExistingRecipesRoundTrip() throws {
        let recipes = [try draft().makeRecipe()] + SampleRecipes.all
        let decoded = try JSONDecoder().decode([Recipe].self, from: JSONEncoder().encode(recipes))
        XCTAssertEqual(decoded, recipes)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SampleRecipes.simplePasta)) as? [String: Any])
        old.removeValue(forKey: "sourceURL"); old.removeValue(forKey: "importNotes")
        XCTAssertNoThrow(try JSONDecoder().decode(Recipe.self, from: JSONSerialization.data(withJSONObject: old)))
    }
    func testImporterUsesOnlyConfiguredHTTPSBackendOrigin() throws {
        let service = try RecipeImportService(backendURL: "https://backend.example/v1/cooking/observe?x=1", accessToken: "token")
        XCTAssertEqual(service.endpoint.absoluteString, "https://backend.example/v1/recipes/import")
        XCTAssertThrowsError(try RecipeImportService(backendURL: "http://backend.example", accessToken: "token"))
        XCTAssertThrowsError(try RecipeImportService(backendURL: "https://backend.example", accessToken: ""))
    }
}
