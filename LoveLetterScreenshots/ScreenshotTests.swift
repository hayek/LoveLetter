import XCTest

/// Captures the marketing / App Store screenshots on the DEBUG mock dataset.
///
/// Don't run this directly — `Scripts/screenshots.sh` builds it for Mac, iPhone and iPad, runs it
/// and exports the images into `<output>/<platform>/<appearance>/NN-name.png`. Each image is an
/// `XCTAttachment` named `<platform>_<appearance>_NN-name`; the script keys off that name.
///
/// Every shot relaunches the app, so one broken screen fails its own shot and the rest still run.
/// Copy or UI changes that move a label only need the matching query below updated.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var appearance = "light"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testLightAppearance() { captureAll(appearance: "light") }
    func testDarkAppearance() { captureAll(appearance: "dark") }

    // MARK: - Shot list

    private func captureAll(appearance: String) {
        self.appearance = appearance
        #if os(macOS)
        macShots()
        #else
        iOSShots()
        #endif
    }

    #if os(macOS)
    private func macShots() {
        shot("01-feedback") {
            try self.waitForFeedback()
        }
        shot("02-feedback-second-product") {
            try self.waitForFeedback()
            try self.activate(self.text("Tidy Budget"))
            _ = try self.element(self.text("CSV import skips rows with commas in the payee"))
            self.waitForSummary()
        }
        shot("03-reply-composer") {
            try self.waitForFeedback()
            try self.activate(self.button("Reply"))
            try self.element(self.button("Send"))
            self.waitForSummary()   // opening a card marks it read, which re-runs the summary
        }
        shot("04-reply-templates") {
            try self.waitForFeedback()
            try self.activate(self.button("Reply with template"))
            try self.element(self.text("Reply Templates"))
            self.waitForSummary()
        }
        shot("05-task-detail") {
            try self.waitForFeedback()
            try self.openTask()
        }
        shot("06-delete-task-alert") {
            try self.waitForFeedback()
            try self.openTask()
            try self.activate(self.button("Delete Task"))
            self.settle()
        }
        shot("07-version-detail") {
            try self.waitForFeedback()
            try self.activate(self.versionCard("2.4.0"))
            self.settle()
        }
        shot("08-new-task") {
            try self.waitForFeedback()
            try self.activate(self.button("New Task"))
            self.settle()
        }
        shot("09-new-version") {
            try self.waitForFeedback()
            try self.activate(self.button("New Version"))
            self.settle()
        }
        shot("10-remove-product-alert") {
            try self.waitForFeedback()
            try self.activate(self.text("Pixel Journal"), secondary: true)
            try self.activate(self.app.menuItems["Remove Product"])
            self.settle()
        }
        shot("11-settings-product", window: .settings) {
            try self.openSettings()
        }
        shot("12-settings-email", window: .settings) {
            try self.openSettings(pane: "Email")
        }
        shot("13-settings-intelligence", window: .settings) {
            try self.openSettings(pane: "Intelligence")
        }
        // No "CLI & AI Skill" shot: that pane shows this Mac's real install paths (home folder).
        shot("14-add-product", window: .settings) {
            try self.openSettings()
            // The sidebar's section header folds its "+" button into one text element
            // ("Products, Add Product"), so click the header's trailing edge where the "+" sits.
            let header = try self.element(self.settingsWindow.staticTexts["Products, Add Product"])
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
            _ = try self.element(self.text("Add Product"))
            self.settle()
        }
    }

    private func openSettings(pane: String? = nil) throws {
        try waitForFeedback()
        app.typeKey(",", modifierFlags: .command)
        let window = try element(settingsWindow)
        if let pane {
            try activate(window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", pane, pane)).firstMatch)
        }
        settle()
    }
    #else
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func iOSShots() {
        shot("01-feedback") {
            try self.waitForFeedback()
        }
        shot("02-products") {
            try self.waitForFeedback()
            try self.showSidebar()
        }
        shot("03-tasks-and-versions") {
            try self.waitForFeedback()
            try self.openTasksPanel()
        }
        shot("04-reply-composer") {
            try self.waitForFeedback()
            try self.activate(self.button("Reply"))
            try self.element(self.button("Send"))
            self.hideKeyboard()
            self.waitForSummary()   // opening a card marks it read, which re-runs the summary
        }
        shot("05-reply-templates") {
            try self.waitForFeedback()
            try self.activate(self.button("Reply with template"))
            try self.element(self.text("Reply Templates"))
            self.waitForSummary()
        }
        shot("06-task-detail") {
            try self.waitForFeedback()
            try self.openTasksPanel()
            try self.openTask()
        }
        shot("07-delete-task-alert") {
            try self.waitForFeedback()
            try self.openTasksPanel()
            try self.openTask()
            let delete = self.button("Delete Task")
            if !delete.isHittable { self.app.swipeUp() }
            try self.activate(delete)
            self.settle()
        }
        shot("08-version-detail") {
            try self.waitForFeedback()
            try self.openTasksPanel()
            let version = self.versionCard("2.4.0")
            if !version.waitForExistence(timeout: 2) || !version.isHittable { self.app.swipeUp() }
            try self.activate(version)
            self.settle()
        }
        shot("09-new-task") {
            try self.waitForFeedback()
            try self.openTasksPanel()
            try self.activate(self.button("New Task"))
            self.settle()
        }
        shot("10-settings") {
            try self.openSettings()
        }
        shot("11-settings-product") {
            try self.openSettings()
            try self.activate(self.text("Pixel Journal"))
            self.settle()
        }
        shot("12-settings-email") {
            try self.openSettings()
            try self.activate(self.button("Email"))
            self.settle()
        }
        shot("13-add-product") {
            try self.openSettings()
            try self.activate(self.button("Add Product"))
            _ = try self.element(self.app.navigationBars["Add Product"])
            self.settle()
        }
    }

    /// iPhone opens on the feedback list; the sidebar is one Back tap away. iPad shows it already
    /// unless the split view collapsed it.
    private func showSidebar() throws {
        let products = app.staticTexts["Tidy Budget"]
        if products.waitForExistence(timeout: 1), products.isHittable { return }
        let back = app.navigationBars.buttons.element(boundBy: 0)
        try activate(back)
        _ = try element(products)
        settle()
    }

    /// The composer focuses its body, which raises the on-screen keyboard on iPad. Best effort:
    /// the iPad keyboard's dismiss key, if one is showing.
    private func hideKeyboard() {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 2) else { return }
        let dismiss = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'keyboard'")).firstMatch
        // A coordinate tap: `tap()` first scrolls the key "to visible", which can fail and abort the run.
        if dismiss.exists { dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    private func openTasksPanel() throws {
        try activate(button("Tasks & Versions"))
        _ = try element(button("New Task"))
        settle()
    }

    private func openSettings() throws {
        try waitForFeedback()
        if !button("Settings").exists || !button("Settings").isHittable {
            try showSidebar()
        }
        try activate(button("Settings"))
        _ = try element(app.navigationBars["Settings"])
        settle()
    }
    #endif

    // MARK: - Shared steps

    /// The first mock product's newest feedback — present once the seeded list has rendered.
    private func waitForFeedback() throws {
        _ = try element(text("Photos disappear after editing an entry"), timeout: 20)
        waitForSummary()
    }

    /// The on-device AI summary above the list starts after it renders and streams in; capture it
    /// finished. Best effort: without Apple Intelligence it never finishes, so don't fail the shot.
    private func waitForSummary() {
        let finished = app.staticTexts.matching(NSPredicate(format: """
            label CONTAINS[c] 'needs attention' OR value CONTAINS[c] 'needs attention'
            OR label CONTAINS[c] "what's working" OR value CONTAINS[c] "what's working"
            OR label BEGINSWITH "Couldn't generate summary" OR value BEGINSWITH "Couldn't generate summary"
            """)).firstMatch
        _ = finished.waitForExistence(timeout: 45)
        settle()
    }

    /// A version card in the Tasks & Versions panel; its button label reads "2.4.0, 2 tasks, …".
    private func versionCard(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    private func openTask() throws {
        try activate(text("Keep all photos when saving an edited entry"))
        _ = try element(button("Delete Task"))
        settle()
    }

    // MARK: - Engine

    /// Which macOS window a shot captures; iOS always captures the whole screen.
    private enum Window { case main, settings }

    private struct MissingElement: Error, CustomStringConvertible {
        let query: String
        var description: String { "Timed out waiting for \(query)" }
    }

    /// Relaunches the app on mock data, runs `navigate`, and attaches a screenshot. A failure is
    /// recorded against this shot only.
    private func shot(_ name: String, window: Window = .main, _ navigate: @escaping () throws -> Void) {
        let fullName = "\(Self.platform)_\(appearance)_\(name)"
        XCTContext.runActivity(named: fullName) { _ in
            launch()
            do {
                try navigate()
            } catch {
                // What the app showed instead, and its element tree, to fix the query from.
                let state = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                state.name = "failed-\(fullName)"
                state.lifetime = .keepAlways
                add(state)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "failed-\(fullName)-tree"
                tree.lifetime = .keepAlways
                add(tree)
                XCTFail("\(fullName): \(error)")
                return
            }
            let attachment = XCTAttachment(screenshot: screenshot(window: window))
            attachment.name = fullName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func launch() {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments += [
            "-debug.useMockData", "YES",
            "-LLScreenshotMode", "YES",
            "-LLAppearance", appearance,
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        #if os(macOS)
        app.launchArguments += [
            "-LLWindowSize", ProcessInfo.processInfo.environment["LL_WINDOW_SIZE"] ?? "1440x900",
            "-LLSettingsWindowSize", ProcessInfo.processInfo.environment["LL_SETTINGS_WINDOW_SIZE"] ?? "1152x720",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        #endif
        app.launch()
    }

    #if os(macOS)
    // The Settings window retitles itself after the selected pane; its scene id is stable.
    // The main window's title follows whatever sheet it presents, so match its scene identifier.
    private var mainWindow: XCUIElement { app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'SwiftUI.WindowGroup'")).firstMatch }
    private var settingsWindow: XCUIElement { app.windows["settings"] }
    #endif

    private func screenshot(window: Window) -> XCUIScreenshot {
        #if os(macOS)
        let target = window == .main ? mainWindow : settingsWindow
        return target.exists ? target.screenshot() : XCUIScreen.main.screenshot()
        #else
        return XCUIScreen.main.screenshot()
        #endif
    }

    /// Lets transitions, sheet presentations and async images finish before capturing.
    private func settle(_ seconds: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @discardableResult
    private func element(_ element: XCUIElement, timeout: TimeInterval = 8) throws -> XCUIElement {
        guard element.waitForExistence(timeout: timeout) else {
            throw MissingElement(query: element.debugDescription.split(separator: "\n").first.map(String.init) ?? "\(element)")
        }
        return element
    }

    /// Clicks (macOS) or taps (iOS) `element` once it exists. Elements SwiftUI reports as not
    /// hittable (e.g. text inside a drag container) get a coordinate tap at their center instead,
    /// because a failed XCUI interaction would abort the whole run rather than just this shot.
    private func activate(_ element: XCUIElement, secondary: Bool = false) throws {
        try self.element(element)
        #if os(macOS)
        if secondary {
            element.isHittable ? element.rightClick() : element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        } else {
            element.isHittable ? element.click() : element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        #else
        element.isHittable ? element.tap() : element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        #endif
    }

    private func text(_ label: String) -> XCUIElement {
        // macOS exposes SwiftUI Text through `value`; iOS through `label`.
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", label, label)).firstMatch
    }

    /// Matches `label` exactly or after an icon's name, which SwiftUI folds into button labels
    /// ("Add, New Task") — but not a longer title that merely starts with it ("Reply with template").
    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label ENDSWITH %@ OR title == %@",
                                         label, ", " + label, label)).firstMatch
    }

    private static var platform: String {
        #if os(macOS)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }
}
