import SwiftUI

enum Palette {
    static let cream = Color(red: 0.97, green: 0.96, blue: 0.92)
    static let forest = Color(red: 0.16, green: 0.29, blue: 0.23)
    static let sage = Color(red: 0.85, green: 0.90, blue: 0.80)
    static let orange = Color(red: 0.85, green: 0.39, blue: 0.21)
    static let ink = Color(red: 0.17, green: 0.21, blue: 0.18)
}

struct PrimaryButton: View {
    var title: String
    var icon: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.headline).frame(maxWidth: .infinity).padding(18)
        }.buttonStyle(.plain).foregroundStyle(.white).background(Palette.forest, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(Palette.forest) }
}

struct WatchBadge: View {
    var active: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(active ? Color.green : Color.secondary).frame(width: 7, height: 7)
            Text(active ? "Cooking Watch active" : "Cooking Watch paused").font(.caption.weight(.semibold))
        }.padding(.horizontal, 12).padding(.vertical, 9).background(.white.opacity(0.7), in: Capsule())
    }
}

extension View {
    func cookingCard() -> some View { padding(20).background(.white, in: RoundedRectangle(cornerRadius: 24)) }
}
