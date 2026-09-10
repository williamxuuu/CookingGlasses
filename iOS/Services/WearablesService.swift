import Foundation
import CookingCore

struct WearableStatus {
    var connection = "Disconnected"
    var camera = "Stopped"
    var isMonitoring = false
    var canRenderOnGlasses = false
    var detail = "Start Cooking Watch when you are ready."
}

enum GlassesAction { case undo; case dismissTimer(UUID); case extendTimer(UUID) }

@MainActor protocol WearablesService: AnyObject {
    var status: WearableStatus { get }
    var onStatusChange: ((WearableStatus) -> Void)? { get set }
    var onFrame: ((CameraFrame) -> Void)? { get set }
    var onNavigation: ((Int) -> Void)? { get set }
    var onGlassesAction: ((GlassesAction) -> Void)? { get set }
    func connect() async throws
    func disconnect() async
    func startMonitoring() async throws
    func stopMonitoring() async
    func handleOpenURL(_ url: URL) async
    func render(_ model: GlassesViewModel) async
}
