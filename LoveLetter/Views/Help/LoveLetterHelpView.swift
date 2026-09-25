import SwiftUI
import HelpView

/// The Help & FAQ screen, backed by `Resources/Help/app_help.json` via the HelpView package.
/// Each FAQ carries a stable `key`, so translations can later be added to a `HelpStrings`
/// string catalog (`faq.<key>.title` / `faq.<key>.details`, `topic.<slug>`) without touching the JSON.
struct LoveLetterHelpView: View {
    var body: some View {
        HelpContentView(
            named: "app_help",
            localization: "HelpStrings",
            appContext: """
            Love Letter — a Mac, iPhone and iPad app that gathers feedback about the developer's own apps into one inbox. \
            Each product is backed by a GitHub repository; in-app SDK reports, App Store reviews and support emails all become GitHub issues there. \
            Tasks are issues labeled appfeedback:task and versions are GitHub milestones; releasing a version can email the people whose feedback it fixed. \
            Settings sync through iCloud, credentials live in the Keychain, and the Mac app includes a `loveletter` command-line tool and an AI skill.
            """
        )
    }
}

#if os(macOS)
/// "Love Letter Help" in the Help menu, opening the standalone Help window.
struct HelpMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Love Letter Help") {
            openWindow(id: "help")
        }
        .keyboardShortcut("?", modifiers: .command)
    }
}
#endif
