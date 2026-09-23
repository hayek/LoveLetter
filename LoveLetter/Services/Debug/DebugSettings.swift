#if DEBUG
import Foundation
import Observation

/// DEBUG-only developer toggles, shown in Settings ▸ Debug.
///
/// `useMockData` is the *pending* value the toggle edits. The process reads the flag once at
/// launch (`isMockDataActiveAtLaunch`), because the whole store graph in `LoveLetterApp.init` is
/// built on one `ModelContainer`. So a change only applies after a relaunch; `needsRelaunch`
/// tells the UI when to say so.
@Observable @MainActor
final class DebugSettings {
    static let useMockDataKey = "debug.useMockData"

    static func readUseMockData(from defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: useMockDataKey)
    }

    /// Snapshot taken the first time it's read, which is `LoveLetterApp.init`, before any UI exists.
    static let isMockDataActiveAtLaunch: Bool = readUseMockData(from: .standard)

    @ObservationIgnored private let defaults: UserDefaults
    /// Whether this process is actually running on mock data.
    let mockDataActiveAtLaunch: Bool

    var useMockData: Bool {
        didSet { defaults.set(useMockData, forKey: Self.useMockDataKey) }
    }

    var needsRelaunch: Bool { useMockData != mockDataActiveAtLaunch }

    init(defaults: UserDefaults = .standard, mockDataActiveAtLaunch: Bool? = nil) {
        self.defaults = defaults
        self.useMockData = Self.readUseMockData(from: defaults)
        self.mockDataActiveAtLaunch = mockDataActiveAtLaunch ?? Self.isMockDataActiveAtLaunch
    }
}
#endif
