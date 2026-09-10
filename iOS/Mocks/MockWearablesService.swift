import Foundation
import CookingCore

@MainActor final class MockWearablesService: WearablesService {
    var status = WearableStatus(connection: "Mock glasses", camera: "Stopped", detail: "Simulator mode · no camera uploads")
    var onStatusChange: ((WearableStatus) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onNavigation: ((Int) -> Void)?
    var onGlassesAction: ((GlassesAction) -> Void)?
    private(set) var renderedModel: GlassesViewModel?
    func connect() async throws { status.connection = "Mock connected"; onStatusChange?(status) }
    func disconnect() async { await stopMonitoring(); status.connection = "Disconnected"; onStatusChange?(status) }
    func startMonitoring() async throws {
        try await connect(); status.camera = "Mock streaming"; status.isMonitoring = true
        status.detail = "Mock Watch active · use Debug to simulate cooking actions"
        onStatusChange?(status)
    }
    func stopMonitoring() async {
        status.camera = "Stopped"; status.isMonitoring = false
        status.detail = "Cooking Watch paused — timers still running."
        onStatusChange?(status)
    }
    func simulateDisconnect() {
        status.connection = "Disconnected"; status.camera = "Paused"; status.isMonitoring = false
        status.detail = "Cooking Watch paused — timers still running."; onStatusChange?(status)
    }
    func handleOpenURL(_ url: URL) async {}
    func render(_ model: GlassesViewModel) async { renderedModel = model }
}
