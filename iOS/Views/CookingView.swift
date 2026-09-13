import SwiftUI
import CookingCore

struct CookingView: View {
    @EnvironmentObject private var store: CookingSessionStore
    @State private var showCorrection = false
    @State private var showAddTimer = false
    var body: some View {
        ScrollView {
            if let session = store.session {
                VStack(alignment: .leading, spacing: 22) {
                    HStack { WatchBadge(active: store.status.isMonitoring); Spacer(); NavigationLink { DebugCameraView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Debug and settings").accessibilityIdentifier("open_debug") }
                    Text(session.recipe.title).font(.system(size: 31, design: .serif))
                    HStack(spacing: 5) {
                        ForEach(Array(session.recipe.steps.enumerated()), id: \.element.id) { index, step in
                            Capsule().fill(session.completedStepIDs.contains(step.id) ? Palette.forest : (index == session.currentStepIndex ? Palette.orange : Palette.sage)).frame(height: 5)
                        }
                    }.accessibilityLabel("Step \(session.currentStepIndex + 1) of \(session.recipe.steps.count)")
                    VStack(alignment: .leading, spacing: 14) {
                        RecipeStepPager(session: session) { index in
                            guard let current = store.session else { return }
                            store.navigate(index - current.currentStepIndex)
                        }.id(session.id)
                        if let checkpoints = session.currentStep.requiredEventSequence, !checkpoints.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Live checkpoints").font(.headline)
                                ForEach(checkpoints, id: \.rawValue) { event in
                                    HStack {
                                        Image(systemName: session.observedAt(event) != nil ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(session.observedAt(event) != nil ? Palette.forest : Palette.ink.opacity(0.4))
                                        Text(event.displayName)
                                        Spacer()
                                        if let time = session.observedAt(event) {
                                            Text(time.formatted(date: .omitted, time: .standard)).font(.caption).monospacedDigit()
                                        }
                                    }.accessibilityIdentifier("checkpoint_\(event.rawValue)")
                                }
                                if let next = session.expectedEvents.first { Text("Watching for: \(next.watchInstruction)").font(.subheadline.weight(.medium)) }
                                Text(store.mockAIEvents ? "Simulation is on — turn Mock AI Events off in settings for the camera test." : store.lastObservationResult)
                                    .font(.caption).foregroundStyle(.secondary)
                                if let latency = store.lastVisionLatency { Text(String(format: "Last check took %.1f seconds", latency)).font(.caption).foregroundStyle(.secondary) }
                                Text("Keep Sous open and the phone unlocked. Start Watch before pouring; let each checkpoint register before the next action.").font(.caption).foregroundStyle(.secondary)
                                Button("Reset test checkpoints") { store.correct(to: session.currentStepIndex) }.font(.subheadline)
                            }.cookingCard()
                        }
                        if session.recipe.steps.count > 1 {
                            HStack {
                                Image(systemName: "chevron.left")
                                Spacer()
                                Text("Swipe left for next · right for previous")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }.font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        PrimaryButton(title: "Mark done", icon: "checkmark") { store.markDone() }.accessibilityIdentifier("mark_done").disabled(!session.currentStep.prerequisiteStepIDs.isSubset(of: session.completedStepIDs))
                        if !session.currentStep.prerequisiteStepIDs.isSubset(of: session.completedStepIDs) {
                            Text("Complete earlier steps first, or use Correct recipe state below.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let pending = session.pendingObservation {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("A quick check", systemImage: "questionmark.bubble").font(.headline)
                            Text(pending.event.confirmationPrompt)
                            HStack { Button("Yes, that's right") { store.confirmObservation() }.buttonStyle(.borderedProminent); Button("No") { store.rejectObservation() }.buttonStyle(.bordered) }
                        }.cookingCard()
                    }
                    if let action = session.lastAction {
                        HStack { Image(systemName: "sparkle"); Text(action).font(.subheadline); Spacer(); if session.canUndo { Button("Undo") { store.undo() }.font(.subheadline.weight(.bold)) } }.padding(16).background(Palette.sage, in: RoundedRectangle(cornerRadius: 18))
                    }
                    TimerListView()
                    Button { showAddTimer = true } label: { Label("Add another timer", systemImage: "plus.circle").font(.subheadline.weight(.semibold)) }
                    if session.currentStep.optionalTimer != nil {
                        Button { store.startTimer() } label: { Label("Start this step's timer", systemImage: "timer").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large).disabled(!session.currentStep.prerequisiteStepIDs.isSubset(of: session.completedStepIDs) || session.timers.contains { !$0.isManual && $0.associatedStepID == session.currentStep.id })
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Image(systemName: "eyeglasses").font(.title2); Text("Cooking Watch").font(.headline); Spacer() }
                        Text(store.status.detail).font(.subheadline).foregroundStyle(.secondary)
                        PrimaryButton(title: store.watchRequested ? "Pause Cooking Watch" : "Start Cooking Watch", icon: store.watchRequested ? "pause" : "viewfinder") { Task { await store.toggleWatch() } }
                        if !store.status.isMonitoring { Text("Timers keep running while Watch is paused.").font(.caption).foregroundStyle(.secondary) }
                    }.cookingCard()
                    if let model = store.glassesModel { GlassesPreview(model: model) }
                    Button { showCorrection = true } label: { Label("Correct recipe state", systemImage: "arrow.uturn.backward").font(.subheadline) }
                    if session.currentStep.requiredEventSequence == nil {
                        Label("Use a food thermometer for chicken: 165°F / 74°C. Timers and visual appearance cannot confirm safety.", systemImage: "thermometer.medium").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(22)
            } else { ContentUnavailableView("Ready when you are", systemImage: "frying.pan", description: Text("Choose a recipe to start cooking.")) }
        }.background(Palette.cream).navigationTitle("In the kitchen").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .sheet(isPresented: $showAddTimer) { AddTimerView() }
            .sheet(isPresented: $showCorrection) {
                NavigationStack {
                    List {
                        Section { Text("Choose where to restart. Earlier steps will be marked done; this step and later steps will be reset, including their timers. Earlier timers stay intact.").font(.subheadline) }
                        if let session = store.session {
                            ForEach(Array(session.recipe.steps.enumerated()), id: \.element.id) { index, step in
                                Button("\(index + 1). \(step.title)") { store.correct(to: index); showCorrection = false }
                            }
                        }
                    }.navigationTitle("Correct state").navigationBarTitleDisplayMode(.inline).toolbar { Button("Cancel") { showCorrection = false } }
                }
            }
    }
}

private struct RecipeStepPager: View {
    let session: CookingSession
    let select: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The sizing card gives the native pager its current page's full height.
        // Long instructions and larger text can still scroll vertically with the screen.
        card(for: session.currentStepIndex)
            .hidden()
            .overlay {
                TabView(selection: Binding(get: { session.currentStepIndex }, set: select)) {
                    ForEach(session.recipe.steps.indices, id: \.self) { index in
                        card(for: index)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("recipe_step_pages")
                .accessibilityHint("Swipe left for the next step, or right for the previous step.")
                .accessibilityAction(named: "Next step") {
                    select(min(session.currentStepIndex + 1, session.recipe.steps.count - 1))
                }
                .accessibilityAction(named: "Previous step") {
                    select(max(session.currentStepIndex - 1, 0))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: session.currentStepIndex)
    }

    private func card(for index: Int) -> some View {
        let step = session.recipe.steps[index]
        return VStack(alignment: .leading, spacing: 16) {
            Eyebrow(text: "Step \(index + 1) / \(session.recipe.steps.count)")
            Text(step.title).font(.system(size: 30, design: .serif)).accessibilityAddTraits(.isHeader)
            Text(step.fullInstruction).font(.system(size: 18)).lineSpacing(5)
            if session.completedStepIDs.contains(step.id) {
                Label("Step completed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Palette.forest)
            }
            if session.isFinished {
                Label("Recipe steps complete — check food before serving", systemImage: "checkmark.seal").font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .cookingCard()
    }
}

private struct AddTimerView: View {
    @EnvironmentObject private var store: CookingSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var minutes = 5
    var body: some View {
        NavigationStack {
            Form {
                Section("What's cooking?") {
                    TextField("Pasta, sauce, or another dish", text: $label)
                    Stepper("\(minutes) minutes", value: $minutes, in: 1...180)
                }
                Section { Text("This timer keeps running as you move through the recipe.").font(.subheadline) }
                Section {
                    Button("Start timer") { store.addTimer(label: label.trimmingCharacters(in: .whitespacesAndNewlines), minutes: minutes); dismiss() }
                        .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || label.count > 50)
                }
            }.navigationTitle("Add timer").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

struct GlassesPreview: View {
    var model: GlassesViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("GLASSES PREVIEW").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.5); Spacer(); Circle().fill(model.watchActive ? Color.green : Color.gray).frame(width: 6, height: 6) }.foregroundStyle(.white.opacity(0.65))
            if model.expiredTimerID != nil {
                Text("TIMER FINISHED").font(.headline)
                Text("Check \(model.timerLabel ?? "your food").").font(.title3)
            } else {
                Text("STEP \(model.stepNumber) / \(model.totalSteps)").font(.caption.monospaced())
                Text(model.instruction).font(.system(size: 22, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            if let remaining = model.timerRemaining {
                HStack { Text(model.timerLabel ?? "Timer"); Spacer(); Text(timerText(remaining)).monospacedDigit() }.font(.headline).foregroundStyle(Palette.sage)
            }
            if model.additionalTimerCount > 0 { Text("+\(model.additionalTimerCount) timers").font(.caption) }
            HStack { Text(model.expiredTimerID == nil ? "Previous" : "Dismiss"); Spacer(); Text(model.expiredTimerID == nil ? "Next" : "+1 min") }.font(.caption).foregroundStyle(.white.opacity(0.55))
        }.padding(24).foregroundStyle(.white).background(Palette.ink, in: RoundedRectangle(cornerRadius: 24)).accessibilityElement(children: .combine)
    }
}
