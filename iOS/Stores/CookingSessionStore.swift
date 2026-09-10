import SwiftUI
import CookingCore
import UserNotifications

@MainActor final class CookingSessionStore: ObservableObject {
    @Published private(set) var session: CookingSession?
    @Published private(set) var status = WearableStatus()
    @Published var errorMessage: String?
    @Published var mockAIEvents = true { didSet { invalidateInference() } }
    @Published var useRealGlasses = false
    @Published var retainDebugFrame = false { didSet { if !retainDebugFrame { latestFrame = nil } } }
    @Published var latestFrame: UIImage?
    @Published private(set) var frameChangeScore: Double = 0
    @Published private(set) var lastAIRequest: Date?
    @Published private(set) var latestObservation: CookingObservation?
    @Published private(set) var lastObservationResult = "No observations yet"
    @Published var backendURL = UserDefaults.standard.string(forKey: "backendURL") ?? ""
    @Published var backendToken = ""
    @Published private(set) var now = Date()
    @Published private(set) var watchRequested = false
    private(set) var wearables: any WearablesService
    private let stateMachine = RecipeStateMachine()
    private let persistence: SessionPersistence
    private var processor = FrameProcessor()
    private var heartbeat: Timer?
    private var inference: Task<Void, Never>?
    private var inferenceGeneration = UUID()
    private var lastRendered: GlassesViewModel?
    private var changingWatch = false
    private var noticeUntil = Date.distantPast

    init() {
        wearables = MockWearablesService()
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CookingGlasses", isDirectory: true)
        persistence = SessionPersistence(url: directory.appendingPathComponent("session.json"))
        do { session = try persistence.load() } catch { errorMessage = "Your saved session could not be read: \(error.localizedDescription)" }
        wireService()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func wireService() {
        status = wearables.status
        wearables.onStatusChange = { [weak self] value in
            guard let self else { return }
            let shouldResync = self.status.connection != value.connection || self.status.isMonitoring != value.isMonitoring || self.status.canRenderOnGlasses != value.canRenderOnGlasses
            self.status = value
            if value.connection == "Disconnected" || value.connection == "Unavailable" { self.watchRequested = false }
            if !value.isMonitoring { self.invalidateInference(); self.latestFrame = nil }
            if shouldResync { self.lastRendered = nil; self.renderGlasses() }
        }
        wearables.onFrame = { [weak self] frame in self?.receive(frame) }
        wearables.onNavigation = { [weak self] offset in self?.navigate(offset) }
        wearables.onGlassesAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .undo: self.undo()
            case .dismissTimer(let id): self.dismissTimer(id)
            case .extendTimer(let id): self.extendTimer(id)
            }
        }
    }

    func changeHardwareMode(_ real: Bool) async {
        watchRequested = false
        invalidateInference(); latestFrame = nil
        await wearables.disconnect()
        invalidateInference(); latestFrame = nil; lastRendered = nil
        wearables = real ? MetaWearablesService() : MockWearablesService()
        useRealGlasses = real
        wireService()
    }

    func startRecipe(_ recipe: Recipe) {
        invalidateInference()
        noticeUntil = .distantPast
        session = CookingSession(recipe: recipe)
        persist(); renderGlasses()
    }
    func navigate(_ offset: Int) { update { stateMachine.navigate(&$0, offset: offset) } }
    func markDone() { update { stateMachine.markDone(&$0, now: now) } }
    func correct(to index: Int) { update { stateMachine.correct(&$0, toStepIndex: index, now: now) } }
    func undo() { update { stateMachine.undo(&$0, now: now) } }
    func confirmObservation() { update { stateMachine.confirmPending(&$0, now: now) } }
    func rejectObservation() { update { stateMachine.rejectPending(&$0) } }
    func startTimer() {
        guard let session, session.currentStep.prerequisiteStepIDs.isSubset(of: session.completedStepIDs),
              !session.completedStepIDs.contains(session.currentStep.id) else { return }
        update { value in TimerManager.start(for: value.currentStep, in: &value, now: now) }
    }
    func pauseTimer(_ id: UUID) { update { TimerManager.pause(id: id, in: &$0, now: now) } }
    func addTimer(label: String, minutes: Int) {
        var started = false
        update { started = TimerManager.startManual(label: label, duration: TimeInterval(minutes * 60), in: &$0, now: now) }
        if !started { errorMessage = "Could not add this timer. Use a short label and dismiss an existing extra timer if eight are already shown." }
    }
    func resumeTimer(_ id: UUID) { update { TimerManager.resume(id: id, in: &$0, now: now) } }
    func dismissTimer(_ id: UUID) { update { TimerManager.dismiss(id: id, in: &$0) } }
    func extendTimer(_ id: UUID) { update { TimerManager.extend(id: id, in: &$0, by: 60, now: now) } }

    private func update(_ body: (inout CookingSession) -> Void) {
        guard var value = session else { return }
        now = Date()
        invalidateInference()
        body(&value); session = value
        noticeUntil = now.addingTimeInterval(8)
        persist(); renderGlasses()
    }
    private func persist() {
        guard let session else { return }
        do { try persistence.save(session) } catch { errorMessage = "Could not save this session: \(error.localizedDescription)" }
        scheduleTimerNotifications()
    }
    private func tick() {
        now = Date()
        if var value = session {
            let before = value.timers.map { $0.isCompleted }
            TimerManager.refresh(in: &value, now: now)
            if before != value.timers.map({ $0.isCompleted }) { session = value; persist() }
        }
        renderGlasses()
    }
    var glassesModel: GlassesViewModel? {
        guard let session else { return nil }
        var model = GlassesViewModel.make(session: session, watchActive: status.isMonitoring, now: now)
        if now > noticeUntil { model.notice = nil }
        return model
    }
    private func renderGlasses() {
        guard let model = glassesModel, model != lastRendered else { return }
        lastRendered = model
        Task { await wearables.render(model) }
    }

    func toggleWatch() async {
        if watchRequested || status.isMonitoring {
            watchRequested = false
            invalidateInference(); latestFrame = nil
            await wearables.stopMonitoring()
            return
        }
        guard !changingWatch else { return }
        changingWatch = true; defer { changingWatch = false }
        guard session != nil else { return }
        watchRequested = true
        do {
            try await wearables.startMonitoring()
            guard watchRequested else { return }
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if granted == true { scheduleTimerNotifications() }
        } catch {
            if watchRequested { errorMessage = "Cooking Watch could not start: \(error.localizedDescription)" }
            watchRequested = false
        }
    }
    func pauseForBackground() async {
        // No background camera relaunch. Absolute timer deadlines survive suspension.
        watchRequested = false
        invalidateInference(); latestFrame = nil
        await wearables.stopMonitoring(); persist()
    }
    func handleOpenURL(_ url: URL) async { await wearables.handleOpenURL(url) }
    func simulateDisconnect() {
        watchRequested = false; invalidateInference()
        (wearables as? MockWearablesService)?.simulateDisconnect()
    }
    func reconnect() async {
        do { try await wearables.connect(); lastRendered = nil; renderGlasses() }
        catch { errorMessage = error.localizedDescription }
    }

    func inject(_ event: CookingEvent, confidence: Double = 0.96) {
        guard mockAIEvents, watchRequested, status.isMonitoring, var value = session else { return }
        let observation = CookingObservation(event: event, ingredient: "chicken", confidence: confidence, estimatedEventTimestamp: Date())
        latestObservation = observation
        let result = stateMachine.apply(observation, to: &value, now: Date())
        if result == .accepted { noticeUntil = Date().addingTimeInterval(8) }
        lastObservationResult = describe(result)
        session = value; persist(); renderGlasses()
    }
    private func describe(_ result: ObservationResult) -> String {
        switch result {
        case .accepted: return "Accepted · state updated"
        case .needsConfirmation: return "Waiting for your confirmation"
        case .ignored(let reason): return "Ignored · \(reason)"
        }
    }
    private func invalidateInference() {
        inference?.cancel(); inference = nil; inferenceGeneration = UUID(); processor.reset()
    }
    private func receive(_ frame: CameraFrame) {
        guard watchRequested, status.isMonitoring, let current = session else { return }
        if retainDebugFrame { latestFrame = UIImage(data: frame.jpegData) }
        let expects = !current.currentStep.expectedEvents.isEmpty
        let timerWaiting = current.currentStep.optionalTimer != nil && !current.currentStep.requiresContinuousAttention
        let sequence = processor.receive(frame, expectsAction: expects, timerWaiting: timerWaiting)
        frameChangeScore = processor.changeScore
        guard let sequence else { return }
        if mockAIEvents { processor.finishRequest(); return }
        guard let url = URL(string: backendURL), url.scheme == "https", !backendToken.isEmpty else {
            processor.finishRequest(); lastObservationResult = "Configure the HTTPS backend and access token in Debug."; return
        }
        lastAIRequest = frame.timestamp
        let generation = inferenceGeneration, sessionID = current.id, revision = current.revision
        let service = GeminiCookingVisionService(endpoint: url, accessToken: backendToken)
        let request = CookingVisionRequest(recipe: current.recipe, step: current.currentStep, frames: sequence)
        inference = Task { [weak self] in
            do {
                let observation = try await service.observe(request)
                guard let self, !Task.isCancelled, self.inferenceGeneration == generation,
                      self.watchRequested, self.status.isMonitoring, var value = self.session, value.id == sessionID else { return }
                self.latestObservation = observation
                let result = self.stateMachine.apply(observation, to: &value, now: Date(), expectedRevision: revision)
                if result == .accepted { self.noticeUntil = Date().addingTimeInterval(8) }
                self.lastObservationResult = self.describe(result)
                self.session = value; self.processor.finishRequest(); self.persist(); self.renderGlasses()
            } catch {
                guard let self, self.inferenceGeneration == generation, !Task.isCancelled else { return }
                self.processor.finishRequest()
                self.lastObservationResult = "Vision unavailable · manual controls still work"
            }
        }
    }

    func saveBackendSettings() { UserDefaults.standard.set(backendURL, forKey: "backendURL") }
    private func scheduleTimerNotifications() {
        let center = UNUserNotificationCenter.current()
        // App uses only cooking timer notifications; identifiers remain stable across restarts.
        center.removeAllPendingNotificationRequests()
        for timer in session?.timers ?? [] where !timer.isPaused && !timer.isCompleted && !timer.isDismissed {
            let remaining = timer.remaining(at: Date())
            guard remaining > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(timer.label) timer finished"
            content.body = "Check your food. A timer does not determine doneness or safe temperature."
            content.sound = .default
            let request = UNNotificationRequest(identifier: timer.id.uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining), repeats: false))
            center.add(request) { _ in }
        }
    }
}
