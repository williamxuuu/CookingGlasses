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
                ForEach(SampleRecipes.all, id: \.id) { recipe in
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
                }
            }.padding(24)
        }.background(Palette.cream).navigationTitle("Recipes").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .sheet(item: $selection) { recipe in
                NavigationStack {
                    List {
                        Section { Text(recipe.title).font(.title2.weight(.semibold)); Text(recipe.subtitle) }
                        Section("What you'll need") { ForEach(recipe.ingredients, id: \.self) { Text($0) } }
                        Section { Text("Chicken requires a food thermometer reading of 165°F / 74°C. Camera observations and timers never determine safe doneness.").font(.footnote) }
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
