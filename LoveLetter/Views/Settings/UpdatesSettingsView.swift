#if os(macOS)
import SwiftUI

/// Settings pane for the direct-download build's self-updater. Not shown in the App Store
/// flavor (there's no `AppUpdateController` there).
struct UpdatesSettingsView: View {
    @Bindable var updates: AppUpdateController

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current Version", value: currentVersion)
                Toggle("Automatically check for updates", isOn: $updates.checksAutomatically)
            } footer: {
                Text("Checks GitHub for a new Love Letter release at launch and once a day, and "
                     + "downloads it in the background. Nothing is installed until you relaunch.")
            }

            Section {
                HStack {
                    statusLabel
                    Spacer()
                    actionButton
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch updates.status {
        case .idle:
            Text("Not checked yet").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case .upToDate:
            Label("Love Letter is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .downloading(let version, let fraction):
            HStack(spacing: 8) {
                Text("Downloading \(version)…")
                ProgressView(value: fraction).frame(width: 100)
            }
        case .readyToInstall(let version):
            Label("Version \(version) is ready", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label("Couldn't check: \(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if updates.status.isReadyToInstall {
            Button("Update & Relaunch") { updates.installAndRelaunch() }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Check Now") { updates.checkForUpdates() }
                .disabled(updates.status == .checking || updates.status.isDownloading)
        }
    }
}

/// App-menu "Check for Updates…" entry for the direct-download build.
struct CheckForUpdatesCommand: View {
    let updates: AppUpdateController
    /// Passed in: `.commands` content doesn't get the scenes' shared environment.
    let navigation: SettingsNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            navigation.selection = .updates
            openWindow(id: "settings")
            updates.checkForUpdates()
        }
    }
}

/// Offers to relaunch once an update has finished downloading.
struct UpdateReadyAlert: ViewModifier {
    @Bindable var updates: AppUpdateController

    private var version: String {
        if case .readyToInstall(let version) = updates.status { return version }
        return ""
    }

    func body(content: Content) -> some View {
        content.alert("Love Letter \(version) Is Ready", isPresented: $updates.isShowingReadyPrompt) {
            Button("Update & Relaunch") { updates.installAndRelaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The new version has been downloaded. Relaunch now to finish updating, or later "
                 + "from Settings › Updates.")
        }
    }
}

extension View {
    /// No-op when `updates` is nil (App Store flavor, tests, mock mode).
    @ViewBuilder
    func updateReadyAlert(_ updates: AppUpdateController?) -> some View {
        if let updates {
            modifier(UpdateReadyAlert(updates: updates))
        } else {
            self
        }
    }
}
#endif
