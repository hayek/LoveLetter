#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// DEBUG-only hooks for the marketing-screenshot automation (`Scripts/screenshots.sh`, which runs
/// the `LoveLetterScreenshots` UI tests). Driven purely by launch arguments, so nothing persists
/// between launches and a normal run is untouched:
/// - `-LLScreenshotMode YES` turns it on (hides the Debug settings pane, applies the rest);
/// - `-LLAppearance dark|light` forces the appearance of every window, sheet and alert;
/// - `-LLWindowSize 1440x900` / `-LLSettingsWindowSize 1152x720` (macOS) set the main and
///   Settings window frames, in points.
/// Mock data comes from `-debug.useMockData YES`: the argument domain overrides the Debug toggle
/// for that one launch without writing to it.
enum ScreenshotMode {
    static let isActive = UserDefaults.standard.bool(forKey: "LLScreenshotMode")

    private static var isDark: Bool? {
        switch UserDefaults.standard.string(forKey: "LLAppearance")?.lowercased() {
        case "dark": true
        case "light": false
        default: nil
        }
    }

    #if os(macOS)
    private static func windowSize(forKey key: String) -> CGSize? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
    #endif

    /// Forces the requested appearance app-wide. Safe to call repeatedly (e.g. on every appear).
    @MainActor
    static func applyAppearance() {
        guard isActive, let isDark else { return }
        #if os(macOS)
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        #else
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
        #endif
    }

    #if os(macOS)
    /// Sizes and centers `window` to the size under `sizeKey`, so every run yields same-sized images.
    @MainActor
    static func size(_ window: NSWindow, sizeKey: String) {
        guard isActive, let size = windowSize(forKey: sizeKey) else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        window.setFrame(CGRect(origin: origin, size: size), display: true)
    }
    #endif
}

extension View {
    /// Applies `ScreenshotMode` to a window's root view; `sizeKey` names the launch argument that
    /// holds its size (macOS). A no-op unless `-LLScreenshotMode YES`.
    @ViewBuilder
    func screenshotMode(sizeKey: String = "LLWindowSize") -> some View {
        if ScreenshotMode.isActive {
            self
                .onAppear { ScreenshotMode.applyAppearance() }
                #if os(macOS)
                .background(ScreenshotWindowSizer(sizeKey: sizeKey))
                #endif
        } else {
            self
        }
    }
}

#if os(macOS)
/// Hands the hosting window to `ScreenshotMode.size` once it's attached.
private struct ScreenshotWindowSizer: NSViewRepresentable {
    let sizeKey: String

    func makeNSView(context: Context) -> NSView { WindowProbe(sizeKey: sizeKey) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowProbe: NSView {
        private let sizeKey: String
        private var didSize = false

        init(sizeKey: String) {
            self.sizeKey = sizeKey
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didSize else { return }
            didSize = true
            // Next runloop turn: SwiftUI applies its own default frame right after attaching.
            DispatchQueue.main.async { [sizeKey] in ScreenshotMode.size(window, sizeKey: sizeKey) }
        }
    }
}
#endif
#endif
