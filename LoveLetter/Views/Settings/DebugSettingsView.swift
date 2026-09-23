#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings ▸ Debug (DEBUG builds only). The mock-data toggle edits the *pending* value; the app
/// switches data stacks only at launch, so a changed toggle offers a relaunch.
struct DebugSettingsView: View {
    @Environment(DebugSettings.self) private var debugSettings

    var body: some View {
        @Bindable var settings = debugSettings
        return Form {
            Section {
                Toggle("Mock data", isOn: $settings.useMockData)
                if settings.needsRelaunch {
                    relaunchNotice
                }
            } header: {
                Text("Data")
            } footer: {
                Text("Shows fake products, feedback, tasks and releases instead of yours. Your real data is never read, changed or synced while this is on. Applies after relaunch.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var relaunchNotice: some View {
        #if os(macOS)
        HStack {
            Label("Relaunch to apply", systemImage: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Spacer()
            Button("Relaunch Now") { Self.relaunch() }
        }
        #else
        Label("Quit and reopen the app to apply", systemImage: "arrow.clockwise.circle.fill")
            .foregroundStyle(.orange)
        #endif
    }

    #if os(macOS)
    /// Starts a fresh instance of this app, then quits this one once the new one has launched.
    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if error == nil { NSApp.terminate(nil) }
            }
        }
    }
    #endif
}
#endif
