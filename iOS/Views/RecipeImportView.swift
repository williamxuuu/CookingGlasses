import SwiftUI
import PhotosUI
import ImageIO
import CookingCore

struct RecipeImportView: View {
    @EnvironmentObject private var store: CookingSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = 0
    @State private var link = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var jpegPhoto: Data?
    @State private var loadingPhoto = false
    @State private var importing = false
    @State private var error: String?
    @State private var draft: RecipeImportDraft?
    @State private var showReview = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Text("Your recipe, one step at a time.").font(.system(size: 28, design: .serif))
                Text("Choose a recipe photo, or paste a recipe page or YouTube link. Review and edit the steps before saving.").foregroundStyle(.secondary)
            }
            Section("Recipe source") {
                Picker("Source", selection: $source) {
                    Text("Photo").tag(0); Text("Link").tag(1)
                }.pickerStyle(.segmented).disabled(importing)
                if source == 0 {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(jpegPhoto == nil ? "Choose recipe photo" : "Change photo", systemImage: "photo.on.rectangle")
                    }.disabled(importing)
                    if loadingPhoto { ProgressView("Preparing photo…") }
                    if let data = jpegPhoto, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                    }
                    Text("Use a clear photo or screenshot of the written recipe. A photo of the finished dish alone won't provide its recipe.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Paste a recipe or YouTube link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(importing)
                        .accessibilityIdentifier("recipe_import_url")
                    Label("YouTube videos & Shorts", systemImage: "play.rectangle")
                        .font(.subheadline.weight(.medium))
                    Text("Paste a public video showing one recipe. Sous reads its audio and visuals to create ingredients, cooking steps, and short glasses instructions. The whole video is read, even if the link starts partway through.").font(.caption).foregroundStyle(.secondary)
                    Text("Recipe webpages also work. Private videos, Instagram/TikTok links, and pages requiring a login are not supported.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if importing {
                    ProgressView("Reading your recipe…")
                    Text("Videos can take up to 90 seconds. Keep Sous open while it reads.").font(.caption).foregroundStyle(.secondary)
                    Button("Cancel import") { importTask?.cancel() }
                } else {
                    Button("Break into steps", action: beginImport)
                        .font(.headline).disabled(loadingPhoto || (source == 0 ? jpegPhoto == nil : link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("recipe_import_start")
                }
                Text("Your selected photo or link is sent to Gemini through your configured backend when you tap Break into steps.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                NavigationLink("Backend connection settings") { DebugCameraView() }
            }
        }
        .navigationTitle("Import recipe").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .task(id: photoItem) { await loadPhoto() }
        .onDisappear { importTask?.cancel() }
        .sheet(isPresented: $showReview) {
            if let draft {
                NavigationStack {
                    RecipeImportReview(draft: draft) { recipe in
                        try store.saveImportedRecipe(recipe)
                        showReview = false
                        dismiss()
                    }
                }
            }
        }
    }

    private func loadPhoto() async {
        guard let photoItem else { return }
        loadingPhoto = true; jpegPhoto = nil; error = nil
        defer { if !Task.isCancelled { loadingPhoto = false } }
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self), data.count <= 30 * 1024 * 1024 else {
                throw RecipeImportError.message("Choose a photo smaller than 30 MB.")
            }
            try Task.checkCancellation()
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048
                  ] as CFDictionary),
                  let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85), jpeg.count <= 3 * 1024 * 1024 else {
                throw RecipeImportError.message("That image could not be prepared. Try a screenshot of the recipe.")
            }
            jpegPhoto = jpeg // Re-encoding omits the source photo's location/EXIF metadata.
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func beginImport() {
        error = nil; importing = true
        let url = source == 1 ? link.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let photo = source == 0 ? jpegPhoto : nil
        importTask = Task {
            defer { importing = false }
            do {
                let service = try RecipeImportService(backendURL: store.backendURL, accessToken: store.backendToken)
                let result = try await service.importRecipe(url: url, jpegData: photo)
                try Task.checkCancellation()
                draft = result; showReview = true
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

private struct RecipeImportReview: View {
    @State var draft: RecipeImportDraft
    var onSave: (Recipe) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        List {
            Section {
                Text("Check quantities, temperatures and step order against the original. Use Edit to remove or reorder steps. Mark each step done as you cook.").font(.subheadline)
                if let url = draft.sourceURL, let source = URL(string: url) { Link("Open original recipe", destination: source) }
            }
            if !draft.notes.isEmpty {
                Section("Check against the source") { ForEach(draft.notes, id: \.self) { Text($0).foregroundStyle(Palette.orange) } }
            }
            Section("Recipe") {
                TextField("Recipe title", text: $draft.title)
                TextField("Description", text: $draft.subtitle, axis: .vertical)
            }
            Section("Ingredients · one per line") {
                TextEditor(text: Binding(get: { draft.ingredients.joined(separator: "\n") }, set: {
                    draft.ingredients = $0.components(separatedBy: "\n")
                })).frame(minHeight: 150)
            }
            Section("Steps") {
                ForEach($draft.steps) { $step in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("STEP \((draft.steps.firstIndex(where: { $0.id == step.id }) ?? 0) + 1)").font(.caption.weight(.semibold)).foregroundStyle(Palette.forest)
                        TextField("Step title", text: $step.title).font(.headline)
                        TextField("Full instruction", text: $step.instruction, axis: .vertical)
                        TextField("Short glasses instruction", text: $step.glassesInstruction, axis: .vertical).font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Text("Timer (minutes)")
                            Spacer()
                            TextField("0", value: Binding<Double>(get: { Double(step.timerSeconds) / 60 }, set: {
                                if $0.isFinite && (0...1440).contains($0) { step.timerSeconds = Int(($0 * 60).rounded()) }
                            }), format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        }.font(.subheadline)
                    }.padding(.vertical, 8)
                }
                .onDelete { draft.steps.remove(atOffsets: $0) }
                .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }
                Text("0 minutes means no timer. Timers are reminders to check the food.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Save to my recipes") {
                    do {
                        draft.ingredients = draft.ingredients.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        try onSave(draft.makeRecipe())
                    } catch { self.error = error.localizedDescription }
                }.font(.headline).accessibilityIdentifier("recipe_import_save")
            }
        }.navigationTitle("Review recipe").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
    }
}
