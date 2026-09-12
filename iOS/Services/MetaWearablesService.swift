import Foundation
import CookingCore
import MWDATCore
import MWDATCamera
import MWDATDisplay

/// The only SDK-facing service. All symbols are checked against DAT's 0.9.0
/// XCFramework Swift interfaces; recipe and timer state never live here.
@MainActor
final class MetaWearablesService: WearablesService {
    private(set) var status = WearableStatus(
        connection: "Not connected", camera: "Off", isMonitoring: false,
        canRenderOnGlasses: false, detail: "Connect Meta Ray-Ban Display glasses to begin."
    ) {
        didSet {
            // A failed display send may publish the same detail repeatedly.
            // Avoid a status → render → identical error feedback loop.
            guard status.connection != oldValue.connection || status.camera != oldValue.camera ||
                    status.isMonitoring != oldValue.isMonitoring ||
                    status.canRenderOnGlasses != oldValue.canRenderOnGlasses ||
                    status.detail != oldValue.detail else { return }
            onStatusChange?(status)
        }
    }
    var onStatusChange: ((WearableStatus) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onNavigation: ((Int) -> Void)?
    var onGlassesAction: ((GlassesAction) -> Void)?

    private var configured = false
    private var lifecycleGeneration = UUID()
    private var monitoringGeneration = UUID()
    private var connecting = false
    private var monitoringRequested = false
    private var deviceSelector: AutoDeviceSelector?
    private var lastSessionError: DeviceSessionError?
    private var session: DeviceSession?
    private var camera: MWDATCamera.Camera?
    private var display: MWDATDisplay.Display?
    private var tokens: [any AnyListenerToken] = []
    private var cameraTokens: [any AnyListenerToken] = []
    private var sessionStateTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var latestModel: GlassesViewModel?
    private var pendingModel: GlassesViewModel?
    private var sendingDisplay = false
    private let frameGate: FrameDeliveryGate

    init(maximumDeliveryFrameRate: Double = 2) {
        frameGate = FrameDeliveryGate(minimumInterval: 1 / max(0.1, maximumDeliveryFrameRate))
        do { try configureIfNeeded() }
        catch { status.detail = error.localizedDescription }
    }

    func connect() async throws {
        let generation = lifecycleGeneration
        try configureIfNeeded()
        guard !connecting else { throw AdapterError.message("A glasses connection is already in progress.") }
        connecting = true
        defer { connecting = false }
        if let session {
            switch session.state {
            case .started: return
            case .paused:
                throw AdapterError.message("Glasses session is paused. Wear the glasses and resume the session on the glasses.")
            case .starting: try await waitUntilStarted(session); return
            case .idle, .stopping, .stopped: await releaseSession()
            }
        }
        let wearables = Wearables.shared
        if wearables.registrationState != .registered {
            status.connection = "Registering"
            status.detail = "Complete the connection request in Meta AI."
            try await wearables.startRegistration()
        }
        guard lifecycleGeneration == generation else { throw CancellationError() }
        guard wearables.registrationState == .registered else {
            throw AdapterError.message("Complete registration in Meta AI, then connect again.")
        }

        // Restrict to actual display-capable hardware. Camera-only glasses cannot
        // satisfy this app's on-glasses instruction/navigation experience.
        guard let selector = deviceSelector else { throw CancellationError() }
        status.connection = "Finding glasses"
        status.detail = "App authorized. Waiting for Meta to select available display glasses."
        do {
            // AutoDeviceSelector discovers its active device asynchronously. A
            // session created immediately after init can fail with no eligible device.
            let deadline = Date().addingTimeInterval(20)
            while selector.activeDevice == nil {
                try Task.checkCancellation()
                guard lifecycleGeneration == generation else { throw CancellationError() }
                guard Date() < deadline else {
                    throw AdapterError.message("No live glasses device was selected. If your glasses are connected in Meta AI, tap Update Meta glasses app below: DAT 0.9 requires a compatible glasses app. Then reconnect.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard lifecycleGeneration == generation else { throw CancellationError() }
            let newSession = try wearables.createSession(deviceSelector: selector)
            session = newSession
            lastSessionError = nil
            observe(newSession)
            status.connection = "Connecting"
            status.detail = "Wear the glasses while the session starts."
            try newSession.start() // Synchronous in DAT 0.9.0.
            try await waitUntilStarted(newSession)
            try attachDisplay(to: newSession)
        } catch {
            guard lifecycleGeneration == generation else { throw CancellationError() }
            await releaseSession()
            status.connection = "Unavailable"
            status.detail = error.localizedDescription
            throw error
        }
    }

    func startMonitoring() async throws {
        // Only the explicit user action enters this method. Registration and
        // display connection alone never start camera capture.
        let operation = UUID()
        monitoringGeneration = operation
        try await connect()
        try validateMonitoringOperation(operation)
        guard let session, session.state == .started else {
            throw AdapterError.message("Connect and resume the glasses before starting Cooking Watch.")
        }
        if camera?.stream.state == .streaming { return }
        if camera?.stream.state == .paused {
            throw AdapterError.message("Cooking Watch paused — timers still running. Resume on the glasses.")
        }
        let wearables = Wearables.shared
        var permission = try await wearables.checkPermissionStatus(.camera)
        try validateMonitoringOperation(operation)
        if permission != .granted {
            permission = try await wearables.requestPermission(.camera)
            try validateMonitoringOperation(operation)
        }
        guard permission == .granted else {
            throw AdapterError.message("Camera permission was not granted in Meta AI.")
        }
        guard self.session === session, session.state == .started else {
            throw AdapterError.message("Glasses became unavailable while requesting camera permission.")
        }
        if let camera {
            // A stopped child stream may be started by an explicit user action.
            // Pauses are deliberately not handled by starting a new stream.
            try validateMonitoringOperation(operation)
            monitoringRequested = true
            camera.stream.start()
            return
        }
        do {
            // addStream was removed in 0.9.0: Camera owns the stream lifecycle.
            let configuration = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 7)
            guard let newCamera = try session.addCamera(config: configuration) else {
                throw AdapterError.message("The device session is not ready to add a camera.")
            }
            camera = newCamera
            observe(newCamera, in: session)
            status.camera = "Starting"
            status.detail = "Cooking Watch is starting."
            try validateMonitoringOperation(operation)
            monitoringRequested = true
            newCamera.stream.start()
        } catch {
            if monitoringGeneration == operation { await stopMonitoring() }
            throw error
        }
    }

    func stopMonitoring() async {
        // Invalidate pending registration/permission awaits before teardown.
        // Their connection may finish, but they can no longer start capture.
        monitoringGeneration = UUID()
        monitoringRequested = false
        // Stopping Camera detaches it and cascades to its child stream. The
        // DeviceSession remains alive so step/timer cards can stay on display.
        camera?.stop()
        camera = nil
        let oldTokens = cameraTokens
        cameraTokens.removeAll()
        status.camera = "Off"
        status.isMonitoring = false
        status.detail = "Cooking Watch off — timers still running."
        // Publish stopped state before yielding. An older stop must not later
        // overwrite status from a newer explicit Watch start during cancellation.
        for token in oldTokens { await token.cancel() }
    }

    func disconnect() async {
        lifecycleGeneration = UUID()
        monitoringGeneration = UUID()
        monitoringRequested = false
        registrationTask?.cancel()
        registrationTask = nil
        devicesTask?.cancel()
        devicesTask = nil
        await releaseSession()
        configured = false
        deviceSelector = nil
        latestModel = nil
        pendingModel = nil
        status = WearableStatus(connection: "Disconnected", camera: "Off", isMonitoring: false,
                                canRenderOnGlasses: false, detail: "Glasses disconnected — timers still running.")
    }

    func handleOpenURL(_ url: URL) async {
        do {
            try configureIfNeeded()
            _ = try await Wearables.shared.handleUrl(url)
        } catch {
            status.detail = "Meta AI callback: \(error.localizedDescription)"
        }
    }

    func openGlassesAppUpdate() async throws {
        try configureIfNeeded()
        // The glasses-side DAT app has its own update flow, separate from iOS
        // App Store updates and general glasses firmware. Same API as DisplayAccess.
        try await Wearables.shared.openDATGlassesAppUpdate()
    }

    func render(_ model: GlassesViewModel) async {
        latestModel = model
        pendingModel = model
        guard !sendingDisplay, let display, display.state == .started else { return }
        sendingDisplay = true
        defer { sendingDisplay = false }
        // Send serially, coalescing timer ticks. An older async send must never
        // overwrite a newer recipe state after it finishes out of order.
        while let next = pendingModel, self.display === display, display.state == .started {
            pendingModel = nil
            let content = DATGlassesRenderer.makeCard(next, navigation: { [weak self] offset in
                Task { @MainActor in self?.onNavigation?(offset) }
            }, action: { [weak self] action in
                Task { @MainActor in self?.onGlassesAction?(action) }
            })
            do {
                try await display.send(content)
            } catch {
                status.detail = "Glasses display update failed: \(error.localizedDescription)"
                break
            }
        }
    }

    private func configureIfNeeded() throws {
        guard !configured else { return }
        do { try Wearables.configure() }
        catch WearablesError.alreadyConfigured { /* Another app component configured DAT. */ }
        configured = true
        // Match Meta's DisplayAccess sample: retain the selector across sessions.
        deviceSelector = AutoDeviceSelector(wearables: Wearables.shared, filter: { $0.supportsDisplay() })
        registrationTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                guard !Task.isCancelled else { break }
                if self?.session == nil, self?.connecting == false {
                    self?.status.connection = state == .registered ? "Registered" : state.description
                }
            }
        }
        devicesTask = Task { [weak self] in
            for await devices in Wearables.shared.devicesStream() {
                guard !Task.isCancelled else { break }
                guard let self, self.session == nil else { continue }
                let hasDisplay = devices.contains {
                    Wearables.shared.deviceForIdentifier($0)?.supportsDisplay() == true
                }
                // Discovery is not an active display session.
                self.status.canRenderOnGlasses = false
                if hasDisplay && !self.connecting {
                    self.status.detail = "Display glasses available. Connect to resynchronize the current recipe."
                }
            }
        }
    }

    private func waitUntilStarted(_ target: DeviceSession) async throws {
        let deadline = Date().addingTimeInterval(20)
        while target.state != .started {
            try Task.checkCancellation()
            guard session === target else { throw CancellationError() }
            if target.state == .stopped {
                // DAT 0.9 closes errorStream at .stopped. Drain buffered errors
                // before cleanup so a specific SDK failure is never replaced.
                await sessionErrorTask?.value
                if let error = lastSessionError { throw error }
                throw AdapterError.message("Meta ended the glasses session without reporting a reason. Check that Sous has Bluetooth and Local Network access in iPhone Settings.")
            }
            if let error = lastSessionError { throw error }
            guard Date() < deadline else {
                throw AdapterError.message("Glasses connection timed out. Check Meta AI, wear state, and Developer Mode.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func validateMonitoringOperation(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard monitoringGeneration == operation else { throw CancellationError() }
    }

    private func observe(_ target: DeviceSession) {
        // Subscribe synchronously BEFORE start(), as in Meta's DisplayAccess.
        // Creating these inside Task misses one-shot startup errors.
        let stateStream = target.stateStream()
        let errorStream = target.errorStream()
        sessionStateTask = Task { [weak self] in
            // 0.9.0 finishes this sequence after delivering .stopped. A terminal
            // session is never reused: the user reconnects to create a new one.
            for await state in stateStream {
                guard !Task.isCancelled, let self, self.session === target else { break }
                switch state {
                case .started:
                    self.status.connection = "Connected"
                    self.status.isMonitoring = self.monitoringRequested && self.camera?.stream.state == .streaming
                    if self.status.isMonitoring { self.status.camera = "Streaming" }
                    self.status.detail = self.monitoringRequested ? "Cooking Watch is resuming." : "Glasses connected."
                    do { try self.attachDisplay(to: target) }
                    catch { self.status.detail = "Display unavailable: \(error.localizedDescription)" }
                    if let model = self.latestModel { await self.render(model) }
                case .paused:
                    self.status.connection = "Paused"
                    self.status.camera = self.monitoringRequested ? "Paused" : "Off"
                    self.status.isMonitoring = false
                    self.status.detail = "Cooking Watch paused — timers still running."
                    // DAT owns pause/resume. Do not start another session/camera.
                case .stopped:
                    self.monitoringRequested = false
                    self.status.connection = "Disconnected"
                    self.status.camera = "Paused"
                    self.status.isMonitoring = false
                    self.status.canRenderOnGlasses = false
                    self.status.detail = "Cooking Watch paused — timers still running. Reconnect, then start Watch to resume."
                    // Keep observers until buffered SDK errors drain.
                    // Reconnect/disconnect owns terminal session teardown.
                case .idle, .starting, .stopping: break
                }
            }
        }
        sessionErrorTask = Task { [weak self] in
            for await error in errorStream {
                guard !Task.isCancelled, let self, self.session === target else { break }
                self.lastSessionError = error
                self.status.detail = error.localizedDescription
                self.status.isMonitoring = false
            }
        }
        if let device = Wearables.shared.deviceForIdentifier(target.deviceId) {
            tokens.append(device.addLinkStateListener { [weak self] state in
                Task { @MainActor in
                    guard let self, self.session === target else { return }
                    if state == .disconnected {
                        self.status.connection = "Disconnected"
                        self.status.camera = "Paused"
                        self.status.isMonitoring = false
                        self.status.detail = "Cooking Watch paused — timers still running."
                    }
                }
            })
        }
    }

    private func attachDisplay(to target: DeviceSession) throws {
        guard display == nil, target.state == .started else { return }
        let newDisplay = try target.addDisplay()
        display = newDisplay
        tokens.append(newDisplay.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.display === newDisplay else { return }
                self.status.canRenderOnGlasses = state == .started
                if state == .started, let model = self.latestModel { await self.render(model) }
            }
        })
        newDisplay.start()
    }

    private func observe(_ target: MWDATCamera.Camera, in deviceSession: DeviceSession) {
        let stream = target.stream
        cameraTokens.append(target.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.camera === target, state == .stopped else { return }
                // A stopped Camera is detached; retain no dead capability. The
                // next explicit Watch start must call addCamera again.
                self.camera = nil
                let oldTokens = self.cameraTokens
                self.cameraTokens.removeAll()
                self.status.camera = "Paused"
                self.status.isMonitoring = false
                self.status.detail = "Cooking Watch paused — timers still running."
                for token in oldTokens { await token.cancel() }
            }
        })
        cameraTokens.append(stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.camera === target, self.session === deviceSession else { return }
                switch state {
                case .streaming:
                    self.status.camera = "Streaming"
                    self.status.isMonitoring = self.monitoringRequested && deviceSession.state == .started
                    self.status.detail = "Cooking Watch active. Recent frames stay in memory only."
                case .paused, .stopped:
                    self.status.camera = "Paused"
                    self.status.isMonitoring = false
                    self.status.detail = "Cooking Watch paused — timers still running."
                case .waitingForDevice: self.status.camera = "Waiting for glasses"
                case .starting: self.status.camera = "Starting"
                case .stopping: self.status.camera = "Stopping"
                }
            }
        })
        cameraTokens.append(stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self, self.camera === target else { return }
                self.status.detail = "Camera: \(error.description). Timers still running."
                self.status.isMonitoring = false
            }
        })
        let frameGate = self.frameGate
        cameraTokens.append(stream.videoFramePublisher.listen { [weak self] frame in
            // Drop before queuing actor work. At most one retained SDK frame is
            // waiting for conversion, even if the phone's main actor is busy.
            guard frameGate.begin() else { return }
            let receivedAt = Date()
            Task { @MainActor in
                defer { frameGate.finish() }
                guard let self, self.camera === target, self.monitoringRequested,
                      self.status.isMonitoring, deviceSession.state == .started else { return }
                guard let image = frame.makeUIImage(),
                      let converted = CameraFrame.make(from: image, timestamp: receivedAt) else { return }
                self.onFrame?(converted)
            }
        })
    }

    private func releaseSession() async {
        let oldSession = session
        session = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        camera?.stop()
        camera = nil
        display?.stop()
        display = nil
        oldSession?.stop()
        let oldTokens = tokens + cameraTokens
        tokens.removeAll()
        cameraTokens.removeAll()
        for token in oldTokens { await token.cancel() }
    }
}

/// The publisher may run on any SDK queue. All mutable fields are protected by
/// this lock, allowing synchronous, bounded admission before any Task is made.
private final class FrameDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var pending = false
    private var lastAccepted = -Double.infinity

    init(minimumInterval: TimeInterval) { self.minimumInterval = minimumInterval }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending, now - lastAccepted >= minimumInterval else { return false }
        pending = true
        lastAccepted = now
        return true
    }

    func finish() {
        lock.lock()
        pending = false
        lock.unlock()
    }
}

private enum AdapterError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
