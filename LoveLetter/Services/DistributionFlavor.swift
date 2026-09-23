import Foundation

/// How this build reaches users. Decides whether the app updates itself.
///
/// Set at build time by the `DISTRIBUTION_FLAVOR` build setting (project.yml), which lands in
/// Info.plist as `LLDistributionFlavor`. Everything defaults to `.appStore`; only the website
/// download built by `Scripts/release.sh` is `.direct`.
enum DistributionFlavor: String, Equatable {
    /// Mac App Store / App Store. Updates come from the store; the app must never self-update.
    case appStore = "appstore"
    /// Developer ID build downloaded from the web. Updates itself from GitHub Releases.
    case direct

    static let infoPlistKey = "LLDistributionFlavor"

    static let current = resolve(infoValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String,
                                 hasAppStoreReceipt: bundleHasAppStoreReceipt)

    /// Whether the in-app updater may run at all.
    var usesInAppUpdater: Bool { self == .direct }

    /// A store receipt always wins over the plist value, so a build that ships to the store with
    /// the wrong setting still never self-updates. Unknown or missing values fall back to the
    /// store flavor for the same reason.
    static func resolve(infoValue: String?, hasAppStoreReceipt: Bool) -> DistributionFlavor {
        #if os(macOS)
        if hasAppStoreReceipt { return .appStore }
        return infoValue.flatMap { DistributionFlavor(rawValue: $0.lowercased()) } ?? .appStore
        #else
        return .appStore
        #endif
    }

    /// Mac App Store installs carry `Contents/_MASReceipt/receipt` (TestFlight: `sandboxReceipt`);
    /// Developer ID builds carry neither.
    private static var bundleHasAppStoreReceipt: Bool {
        let dir = Bundle.main.bundleURL.appending(path: "Contents/_MASReceipt")
        return ["receipt", "sandboxReceipt"].contains {
            FileManager.default.fileExists(atPath: dir.appending(path: $0).path)
        }
    }
}
