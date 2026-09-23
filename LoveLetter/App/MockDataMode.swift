import SwiftUI

private struct MockDataModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True only when this process launched in DEBUG mock-data mode (see `DebugSettings`).
    /// Defined in every build so views need no `#if`; only DEBUG code ever sets it to true.
    var isMockDataMode: Bool {
        get { self[MockDataModeKey.self] }
        set { self[MockDataModeKey.self] = newValue }
    }
}

/// Shows a small "MOCK DATA" capsule while `\.isMockDataMode` is on, so demo data is never
/// mistaken for real data. It's a modifier rather than an inline overlay to keep RootView's long
/// modifier chain within the type-checker's budget. Inert in Release.
struct MockDataBadgeOverlay: ViewModifier {
    @Environment(\.isMockDataMode) private var isMockDataMode

    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .bottomLeading) {
            if isMockDataMode {
                Text("MOCK DATA")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Mock data mode")
            }
        }
        #else
        content
        #endif
    }
}
