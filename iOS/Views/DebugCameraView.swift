import SwiftUI
import CookingCore

struct DebugCameraView: View {
    @EnvironmentObject private var store: CookingSessionStore
    var body: some View {
        Form {
            Section("Connection") {
                Toggle("Use physical Meta glasses", isOn: Binding(get: { store.useRealGlasses }, set: { value in Task { await store.changeHardwareMode(value) } }))
                LabeledContent("Glasses", value: store.status.connection)
                LabeledContent("Camera", value: store.status.camera)
                LabeledContent("Native display", value: store.status.canRenderOnGlasses ? "Available" : "Phone preview")
                Text(store.status.detail).font(.caption)
                Button("Connect / reconnect") { Task { await store.reconnect() } }
                if !store.useRealGlasses { Button("Simulate disconnect") { store.simulateDisconnect() } }
                Button(store.watchRequested ? "Pause Cooking Watch" : "Start Cooking Watch") { Task { await store.toggleWatch() } }.disabled(store.session == nil)
            }
            Section("Event simulator") {
                Toggle("Mock AI Events", isOn: $store.mockAIEvents)
                Text("Start Cooking Watch, then mark Season and Heat pan done. Trigger chicken added to advance and start the 5-minute timer. Trigger flip to start the 4-minute timer.").font(.caption)
                ForEach([CookingEvent.chickenAddedToPan, .chickenFlipped, .chickenRemovedFromPan], id: \.rawValue) { event in
                    Button(event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized) { store.inject(event) }.disabled(!store.mockAIEvents || !store.status.isMonitoring)
                }
                Button("Simulate uncertain placement (60%)") { store.inject(.chickenAddedToPan, confidence: 0.60) }.disabled(!store.mockAIEvents || !store.status.isMonitoring)
                Text(store.lastObservationResult).font(.caption)
            }
            Section("Vision diagnostics") {
                LabeledContent("Scene change", value: String(format: "%.3f", store.frameChangeScore))
                LabeledContent("Last AI request", value: store.lastAIRequest?.formatted(date: .omitted, time: .standard) ?? "None")
                LabeledContent("Latest event", value: store.latestObservation?.event.rawValue ?? "None")
                LabeledContent("Confidence", value: store.latestObservation.map { String(format: "%.0f%%", $0.confidence * 100) } ?? "—")
                LabeledContent("Expected", value: store.session?.currentStep.expectedEvents.map(\.rawValue).sorted().joined(separator: ", ") ?? "None")
                LabeledContent("Recipe state", value: store.session?.currentStep.id ?? "No session")
                LabeledContent("Revision", value: String(store.session?.revision ?? 0))
                Toggle("Preview latest frame in memory", isOn: $store.retainDebugFrame)
                Text("Frames are never saved. Preview is cleared when this switch is off or Watch stops.").font(.caption)
                if let frame = store.latestFrame { Image(uiImage: frame).resizable().scaledToFit().frame(maxHeight: 220) }
            }
            Section("Gemini backend") {
                TextField("https://your-server/v1/cooking/observe", text: $store.backendURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Backend access token", text: $store.backendToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save endpoint") { store.saveBackendSettings() }
                Text("Enter your backend token, never a Gemini API key. The token stays in memory and must be entered after relaunch. Turn off Mock AI Events to enable selected-frame uploads.").font(.caption)
            }
            Section("Current timers") { TimerListView() }
            Section("Hardware setup") {
                Text("DAT 0.9.0 · Meta AI Developer Mode or registered app credentials required. Pair supported Meta Display glasses in Meta AI. Camera and display need physical-device validation.").font(.caption)
            }
        }.navigationTitle("Debug & settings").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
