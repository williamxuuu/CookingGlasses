import Foundation
import MWDATDisplay

/// Keep SDK display types out of SwiftUI files: Text and Button otherwise clash
/// with SwiftUI. Native body/heading styles are never reduced to fit text.
/// Physical layout QA must include the longest current safety notice
/// ("Chicken removed — verify 165°F / 74°C"), "Chicken second side" with its
/// timer, and a +timers indicator. Native wrapping depends on the real display;
/// preserve all safety text and use another card if future copy exceeds it.
enum DATGlassesRenderer {
    static func makeCard(
        _ model: GlassesViewModel,
        navigation: @escaping @Sendable (Int) -> Void,
        action: @escaping @Sendable (GlassesAction) -> Void
    ) -> MWDATDisplay.FlexBox {
        MWDATDisplay.FlexBox(direction: .column, spacing: 12) {
            if let timerID = model.expiredTimerID {
                MWDATDisplay.Text("TIMER FINISHED", style: .heading)
                MWDATDisplay.Text(model.timerLabel ?? "Cooking timer", style: .body)
                MWDATDisplay.Text("Check food. Use a thermometer for poultry.", style: .body)
                MWDATDisplay.ButtonGroup {
                    MWDATDisplay.Button(label: "Dismiss", style: .secondary, onClick: {
                        action(.dismissTimer(timerID))
                    })
                    MWDATDisplay.Button(label: "+1 min", onClick: {
                        action(.extendTimer(timerID))
                    })
                }
            } else if let notice = model.notice, model.canUndo {
                // The store expires this action card after eight seconds. Keep
                // the acknowledgment separate from the instruction/nav card so
                // neither card crowds the display or reduces native text size.
                MWDATDisplay.Text("STEP \(model.stepNumber) / \(model.totalSteps)", style: .meta)
                MWDATDisplay.Text(notice, style: .heading)
                if let label = model.timerLabel, let remaining = model.timerRemaining {
                    MWDATDisplay.Text("\(label) · \(clockText(remaining))", style: .body)
                }
                if model.additionalTimerCount > 0 {
                    MWDATDisplay.Text("+\(model.additionalTimerCount) timers", style: .meta, color: .secondary)
                }
                MWDATDisplay.Text(model.watchActive ? "Watch active" : "Watch paused", style: .meta, color: .secondary)
                MWDATDisplay.Button(label: "Undo", style: .secondary, onClick: { action(.undo) })
            } else {
                MWDATDisplay.Text("STEP \(model.stepNumber) / \(model.totalSteps)", style: .meta)
                MWDATDisplay.Text(model.instruction, style: .heading)
                if let label = model.timerLabel, let remaining = model.timerRemaining {
                    MWDATDisplay.Text("\(label) · \(clockText(remaining))", style: .body)
                }
                if model.additionalTimerCount > 0 {
                    MWDATDisplay.Text("+\(model.additionalTimerCount) timers", style: .meta, color: .secondary)
                }
                MWDATDisplay.Text(model.watchActive ? "Watch active" : "Watch paused", style: .meta, color: .secondary)
                MWDATDisplay.ButtonGroup {
                    // These callbacks only navigate; completion/timers are
                    // separate phone-state-machine transitions.
                    MWDATDisplay.Button(label: "Previous", style: .secondary, onClick: { navigation(-1) })
                    MWDATDisplay.Button(label: "Next", onClick: { navigation(1) })
                }
            }
        }.padding(16)
    }

    private static func clockText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(interval)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
