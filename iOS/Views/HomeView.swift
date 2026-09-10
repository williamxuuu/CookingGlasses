import SwiftUI
import CookingCore

struct HomeView: View {
    @EnvironmentObject private var store: CookingSessionStore
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Label("sous", systemImage: "leaf.fill").font(.system(size: 29, weight: .bold, design: .serif))
                        Spacer()
                        NavigationLink { DebugCameraView() } label: { Image(systemName: "slider.horizontal.3").padding(12).background(.white, in: Circle()) }.accessibilityLabel("Debug and settings")
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "A little help. A great meal.")
                        Text("Stay in the\nmoment. Cook.").font(.system(size: 43, weight: .regular, design: .serif)).tracking(-1)
                        Text("Your next step, right in sight.\nYour timers, taken care of.").font(.body).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 32).fill(Palette.sage)
                        Circle().fill(Palette.cream.opacity(0.65)).frame(width: 210, height: 210).offset(x: 75, y: -10)
                        Image(systemName: "frying.pan.fill").font(.system(size: 112, weight: .light)).rotationEffect(.degrees(-25)).foregroundStyle(Palette.forest).offset(x: 30, y: -30)
                        VStack(alignment: .leading, spacing: 5) {
                            Spacer()
                            Label("HANDS FREE. HEADS UP.", systemImage: "eyeglasses").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                            Text("Meet your sous-chef.").font(.system(size: 23, design: .serif))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                    }.frame(height: 246).clipped().clipShape(RoundedRectangle(cornerRadius: 32)).accessibilityElement(children: .combine)
                    NavigationLink { RecipeListView() } label: {
                        HStack { Text("Start Recipe"); Spacer(); Image(systemName: "arrow.right") }.font(.headline).padding(21).foregroundStyle(.white).background(Palette.forest, in: RoundedRectangle(cornerRadius: 18))
                    }.accessibilityIdentifier("start_recipe")
                    HStack(spacing: 14) {
                        NavigationLink { FridgeView() } label: { Label("Scan Fridge", systemImage: "refrigerator").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 20).background(.white, in: RoundedRectangle(cornerRadius: 18)) }
                        NavigationLink { CookingView() } label: { Label("Resume Cooking", systemImage: "play").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 20).background(.white, in: RoundedRectangle(cornerRadius: 18)) }.disabled(store.session == nil)
                    }
                    if let session = store.session {
                        NavigationLink { CookingView() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "flame").font(.title2).foregroundStyle(Palette.orange)
                                VStack(alignment: .leading, spacing: 5) {
                                    Eyebrow(text: "On your stove")
                                    Text(session.recipe.title).font(.headline)
                                    Text("Step \(session.currentStepIndex + 1) of \(session.recipe.steps.count) · \(session.currentStep.title)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right")
                            }.cookingCard()
                        }
                    }
                    Text(store.useRealGlasses ? "META DISPLAY · DAT 0.9.0" : "DEMO MODE · NO GLASSES NEEDED").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(Palette.cream).foregroundStyle(Palette.ink).toolbar(.hidden, for: .navigationBar)
        }
    }
}
