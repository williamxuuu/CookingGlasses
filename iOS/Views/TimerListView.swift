import SwiftUI
import CookingCore

struct TimerListView: View {
    @EnvironmentObject private var store: CookingSessionStore
    var body: some View {
        let timers = (store.session?.timers ?? []).filter { !$0.isDismissed && (!$0.isCompleted || $0.isExpired(at: store.now)) }.sorted { $0.targetEndTime < $1.targetEndTime }
        if !timers.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "On the clock")
                ForEach(timers, id: \.id) { timer in
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Image(systemName: timer.isExpired(at: store.now) ? "bell.badge" : "timer").foregroundStyle(Palette.orange)
                            Text(timer.label).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(timerText(timer.remaining(at: store.now))).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                        if timer.isExpired(at: store.now) { Text("Timer finished. Check your food.").font(.subheadline).foregroundStyle(Palette.orange) }
                        HStack(spacing: 16) {
                            if !timer.isExpired(at: store.now) {
                                Button(timer.isPaused ? "Resume" : "Pause") { if timer.isPaused { store.resumeTimer(timer.id) } else { store.pauseTimer(timer.id) } }
                            }
                            Button("+1 min") { store.extendTimer(timer.id) }
                            Spacer()
                            Button("Dismiss") { store.dismissTimer(timer.id) }
                        }.font(.caption.weight(.semibold))
                    }.cookingCard()
                }
            }
        }
    }
}
