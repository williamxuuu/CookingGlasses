import SwiftUI
import CookingCore

struct RecipeListView: View {
    @EnvironmentObject private var store: CookingSessionStore
    @State private var selection: Recipe?
    @State private var showCooking = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Eyebrow(text: "Tonight, made simple")
                Text("Something good\nis on the menu.").font(.system(size: 35, design: .serif))
                NavigationLink { RecipeImportView() } label: {
                    Label("Import a photo, recipe or YouTube link", systemImage: "square.and.arrow.down").font(.headline).frame(maxWidth: .infinity, alignment: .leading).cookingCard()
                }.accessibilityIdentifier("import_recipe")
                ForEach(store.importedRecipes + SampleRecipes.all, id: \.id) { recipe in
                    Button { selection = recipe } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Image(systemName: recipe.id == SampleRecipes.panSearedChicken.id ? "frying.pan.fill" : "carrot.fill").font(.system(size: 40)).foregroundStyle(Palette.forest)
                                Spacer()
                                Text("\(recipe.steps.count) STEPS").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                            }
                            Text(recipe.title).font(.system(size: 26, design: .serif))
                            Text(recipe.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            HStack { Text("Let's cook").font(.subheadline.weight(.semibold)); Spacer(); Image(systemName: "arrow.up.right") }
                        }.cookingCard()
                    }.buttonStyle(.plain).accessibilityIdentifier("recipe_\(recipe.id)")
                    .contextMenu {
                        if store.importedRecipes.contains(where: { $0.id == recipe.id }) {
                            Button("Delete saved recipe", role: .destructive) { store.deleteImportedRecipe(recipe.id) }
                        }
                    }
                }
            }.padding(24)
        }.background(Palette.cream).navigationTitle("Recipes").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .sheet(item: $selection) { recipe in
                NavigationStack {
                    List {
                        Section { Text(recipe.title).font(.title2.weight(.semibold)); Text(recipe.subtitle) }
                        Section("What you'll need") { ForEach(recipe.ingredients, id: \.self) { Text($0) } }
                        if let url = recipe.sourceURL, let source = URL(string: url) { Section { Link("Original recipe", destination: source) } }
                        if let notes = recipe.importNotes, !notes.isEmpty { Section("Review notes") { ForEach(notes, id: \.self) { Text($0) } } }
                        Section("Steps") {
                            ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { index, step in
                                VStack(alignment: .leading) { Text("\(index + 1). \(step.title)").font(.headline); Text(step.fullInstruction) }
                            }
                        }
                        Section { Text("Use the recipe's food-safety guidance and a food thermometer where appropriate. Camera observations and timers never determine safe doneness.").font(.footnote) }
                        if store.session != nil { Section { Text("Starting this recipe replaces your current cooking session and its timers.").foregroundStyle(Palette.orange) } }
                        Section {
                            Button("Start cooking") { store.startRecipe(recipe); selection = nil; showCooking = true }.font(.headline).accessibilityIdentifier("begin_cooking")
                        }
                    }.navigationTitle("Before you begin").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selection = nil } } }
                }
            }
            .navigationDestination(isPresented: $showCooking) { CookingView() }
    }
}

struct FridgeView: View {
    @State private var selected: Set<String> = []
    private let ingredients = ["Chicken", "Pasta", "Tomato", "Garlic", "Mushrooms", "Olive oil"]
    var body: some View {
        List {
            Section {
                Label("What's in your fridge?", systemImage: "refrigerator").font(.title2)
                Text("Fridge photo recognition is coming later. For this demo, choose your ingredients to find a recipe.").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Your ingredients") {
                ForEach(ingredients, id: \.self) { ingredient in
                    Button { if selected.contains(ingredient) { selected.remove(ingredient) } else { selected.insert(ingredient) } } label: {
                        HStack { Text(ingredient); Spacer(); Image(systemName: selected.contains(ingredient) ? "checkmark.circle.fill" : "circle") }
                    }
                }
            }
            Section("Ideas for tonight") {
                ForEach(SampleRecipes.all.filter { recipe in selected.isEmpty || selected.contains(where: { ingredient in recipe.ingredients.joined(separator: " ").localizedCaseInsensitiveContains(ingredient) }) }, id: \.id) { recipe in
                    Text(recipe.title)
                }
                NavigationLink("Browse recipes") { RecipeListView() }
            }
        }.navigationTitle("Scan Fridge").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
