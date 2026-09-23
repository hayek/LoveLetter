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
