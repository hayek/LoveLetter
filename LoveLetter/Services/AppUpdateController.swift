#if os(macOS)
import AppKit
import AppUpdater
import Combine
import Foundation
import SwiftUI

/// Self-update for the direct-download Mac build (see `DistributionFlavor`), backed by the same
/// GitHub-releases updater as Zcode: `Scripts/release.sh` publishes `LoveLetter-<version>.zip`
/// to `hayek/LoveLetter-releases`, and this downloads, verifies the code signature matches, and
/// swaps the bundle in place.
///
/// Only constructed when the flavor allows it — the App Store build never gets one, so no
/// check can ever run there. The `AppUpdater` itself is created lazily: its init starts a
/// daily background check, so while automatic checks are off it simply doesn't exist.
@MainActor
@Observable
final class AppUpdateController {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(version: String, fraction: Double)
        case readyToInstall(version: String)
        case failed(String)
    }

    static let releasesOwner = "hayek"
    static let releasesRepo = "LoveLetter-releases"
    /// Asset names must be `<prefix>-<tag>.zip` — AppUpdater matches on exactly that.
    static let releasePrefix = "LoveLetter"
    static let automaticChecksKey = "updates.checkAutomatically"

    private(set) var status: Status = .idle
    /// Raised when a download finishes, so the app can offer to relaunch. Views reset it.
    var isShowingReadyPrompt = false

    var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: Self.automaticChecksKey)
            if checksAutomatically {
                checkForUpdates()
            } else if !status.isReadyToInstall {
                tearDownUpdater()   // stops AppUpdater's daily background check
            }
        }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var updater: AppUpdater?
    @ObservationIgnored private var downloadedBundle: Bundle?
    @ObservationIgnored private var stateSubscription: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        checksAutomatically = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    }

    /// Launch hook: checks once (and schedules AppUpdater's daily check) if the user allows it.
    func start() {
        if checksAutomatically { checkForUpdates() }
    }

    func checkForUpdates() {
        guard status != .checking, !status.isDownloading, !status.isReadyToInstall else { return }
        status = .checking
        let updater = makeUpdaterIfNeeded()
        Task {
            do {
                try await updater.checkThrowing()
            } catch {
                apply(checkError: error)
            }
        }
    }

    /// Replaces the running app with the downloaded one and relaunches.
    func installAndRelaunch() {
        guard let updater, let downloadedBundle else { return }
        do {
            try updater.installThrowing(downloadedBundle)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func makeUpdaterIfNeeded() -> AppUpdater {
        if let updater { return updater }
        let updater = AppUpdater(owner: Self.releasesOwner, repo: Self.releasesRepo,
                                 releasePrefix: Self.releasePrefix)
        stateSubscription = updater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                MainActor.assumeIsolated { self?.apply(state: state) }
            }
        self.updater = updater
        return updater
    }

    private func tearDownUpdater() {
        stateSubscription = nil
        updater = nil
        if !status.isDownloading { status = .idle }
    }

    private func apply(state: AppUpdater.UpdateState) {
        switch state {
        case .none:
            break
        case .newVersionDetected(let release, _):
            status = .downloading(version: release.tagName.description, fraction: 0)
        case .downloading(let release, _, let fraction):
            status = .downloading(version: release.tagName.description, fraction: fraction)
        case .downloaded(let release, _, let bundle):
            downloadedBundle = bundle
            status = .readyToInstall(version: release.tagName.description)
            isShowingReadyPrompt = true
        }
    }

    private func apply(checkError error: Error) {
        // AppUpdater reports "already on the latest release" as a cancellation, and "the latest
        // release has no asset for us" as noValidUpdate — neither is a failure to the user.
        if case AUError.cancelled = error {
            status = .upToDate
        } else if case AppUpdater.Error.noValidUpdate = error {
            status = .upToDate
        } else {
            status = .failed(error.localizedDescription)
        }
    }
}

extension AppUpdateController.Status {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isReadyToInstall: Bool {
        if case .readyToInstall = self { return true }
        return false
    }
}

private struct AppUpdateControllerKey: EnvironmentKey {
    static let defaultValue: AppUpdateController? = nil
}

extension EnvironmentValues {
    /// nil unless this is the direct-download flavor running live (see `DistributionFlavor`).
    var appUpdateController: AppUpdateController? {
        get { self[AppUpdateControllerKey.self] }
        set { self[AppUpdateControllerKey.self] = newValue }
    }
}
#endif
