import SwiftUI
import SwiftData
import UserNotifications
import os

// Thread-safe snapshot of repo configs used by the FeedbackAttachmentDownloader
// tokenProvider closure, which must be @Sendable and synchronous.
private final class ProductConfigSnapshot: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[ProductConfig]>(initialState: [])

    func update(_ repos: [ProductConfig]) {
        lock.withLock { $0 = repos }
    }

    func firstToken() -> String? {
        let repos = lock.withLock { $0 }
        for repo in repos {
            if let token = KeychainService.loadSync(for: repo) { return token }
        }
        return nil
    }

    func token(forOwner owner: String, repo: String) -> String? {
        let repos = lock.withLock { $0 }
        for config in repos where config.owner == owner && config.repo == repo {
            if let token = KeychainService.loadSync(for: config) { return token }
        }
        return nil
    }
}

struct LoveLetterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer
    private let repoConfigSnapshot = ProductConfigSnapshot()
    /// True when this process launched in DEBUG mock-data mode (see `DebugSettings`).
    private let isMockDataMode: Bool
    /// `.standard`, or a throwaway suite in mock mode (see `settingsDefaults(for:)`).
    private let settingsDefaults: UserDefaults
    #if DEBUG
    @State private var debugSettings = DebugSettings()
    #endif
    @State private var store: ProductStore
    @State private var versionStore: VersionStore
    @State private var filterStore: FilterPreferenceStore
    @State private var replyTemplateStore: ReplyTemplateStore
    @State private var syncStatus: CloudSyncStatus
    @State private var activityLog: ActivityLog
    @State private var mailAccountStore: MailAccountStore
    @State private var gitHubAccountStore: GitHubAccountStore
    @State private var mailSettingsStore: MailSettingsStore
    @State private var threadStore: MailThreadStore
    @State private var outboundTracker: OutboundSendTracker
    @State private var outboundFailures: OutboundFailureStore
    @State private var settingsNavigation = SettingsNavigation()
    @State private var seenStore: SeenIssueStore
    @State private var cacheContext: ModelContext
    @State private var intelligenceSettings: IntelligenceSettings
    @State private var intelligenceService: IntelligenceService
    @State private var triageSettings: TriageSettings
    @State private var triageCoordinator: FeedbackTriageCoordinator
    @State private var notificationSettings: NotificationSettings
    @State private var notificationService: NotificationService
    @State private var notificationRouter: NotificationRouter
    @State private var downloaderHolder: AttachmentDownloaderHolder
    @State private var coordinatorRegistry: MailSyncCoordinatorRegistry?
    @State private var mirrorHolder: MailToGitHubMirrorHolder
    @State private var feedbackMirrorHolder: MailToFeedbackMirrorHolder
    @State private var appStoreReviewMirrorStore: AppStoreReviewMirrorStore
    @State private var appStoreRegistry: AppStoreReviewCoordinatorRegistry
    @State private var issueLoaderRegistry: IssueLoaderRegistry
    #if os(macOS)
    @State private var cliResponder: CLIRequestResponder
    /// Self-updater; nil unless this is the direct-download flavor running live.
    @State private var appUpdateController: AppUpdateController?
    #endif
    @State private var mailLocalStateStore: MailAccountLocalStateStore
    @State private var mailDraftStore = MailDraftStore()
    @State private var quickLook = QuickLookPresenter()
    @State private var thumbnailCache = ThumbnailCache()
    @State private var feedbackAttachmentDownloaderHolder: FeedbackAttachmentDownloaderHolder
    #if os(iOS)
    @State private var iosRefreshDriver: iOSBackgroundRefreshDriver
    #endif

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let launchMode = Self.resolveLaunchMode(isTesting: isTesting)
        let isMock = launchMode == .mock
        isMockDataMode = isMock
        let settingsDefaultsLocal = Self.settingsDefaults(for: launchMode)
        settingsDefaults = settingsDefaultsLocal
        do {
            container = try Self.makeContainer(mode: launchMode)
        } catch {
            assertionFailure("Failed to create ModelContainer: \(error)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        Self.applySideEffectPolicy(for: launchMode)
        #if DEBUG
        // Seed BEFORE any store is constructed, so their first reload() sees the mock rows.
        if isMock { Self.seedMockData(into: container) }
        #endif
        let cloudContext = ModelContext(container)
        let mailAccountStoreLocal = MailAccountStore(context: ModelContext(container))
        let mailSettingsStoreLocal = MailSettingsStore(context: ModelContext(container))
        let threadStoreLocal = MailThreadStore(context: ModelContext(container))
        if launchMode == .live {
            MailAccountMigration.runIfNeeded(store: mailAccountStoreLocal, settingsStore: mailSettingsStoreLocal)
            MailAccountMigration.runV2IfNeeded(
                accountStore: mailAccountStoreLocal,
                settingsStore: mailSettingsStoreLocal,
                threadStore: threadStoreLocal
            )
            ProductMigration.run(context: cloudContext)
        }
        _mailAccountStore = State(initialValue: mailAccountStoreLocal)
        _mailSettingsStore = State(initialValue: mailSettingsStoreLocal)
        _threadStore = State(initialValue: threadStoreLocal)
        let localStateStoreLocal = MailAccountLocalStateStore(context: ModelContext(container))
        _mailLocalStateStore = State(initialValue: localStateStoreLocal)
        _seenStore = State(initialValue: SeenIssueStore(context: cloudContext))
        _store = State(initialValue: ProductStore(context: ModelContext(container)))
        _gitHubAccountStore = State(initialValue: GitHubAccountStore(context: ModelContext(container)))
        _versionStore = State(initialValue: VersionStore(context: ModelContext(container)))
        _filterStore = State(initialValue: FilterPreferenceStore(context: ModelContext(container)))
        let replyTemplateStoreLocal = ReplyTemplateStore(context: ModelContext(container))
        _replyTemplateStore = State(initialValue: replyTemplateStoreLocal)
        _cacheContext = State(initialValue: ModelContext(container))
        _syncStatus = State(initialValue: CloudSyncStatus())
        // Seed the snapshot so tokenProvider works even before the first repos observation.
        repoConfigSnapshot.update(_store.wrappedValue.repos)
        let activityLogURL: URL? = launchMode != .live ? nil : {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                // On-disk folder from before the rename to Love Letter; do not change.
                .appendingPathComponent("AppFeedback", isDirectory: true)
            return supportDir.appendingPathComponent("activity.json")
        }()
        _activityLog = State(initialValue: ActivityLog(persistenceURL: activityLogURL))
        let failureStoreURL: URL? = launchMode != .live ? nil : {
            let supportDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                // On-disk folder from before the rename to Love Letter; do not change.
                .appendingPathComponent("AppFeedback", isDirectory: true)
            return supportDir.appendingPathComponent("outbound-failures.json")
        }()
        let outboundFailuresLocal = OutboundFailureStore(persistenceURL: failureStoreURL)
        _outboundFailures = State(initialValue: outboundFailuresLocal)
        let outboundTrackerLocal = OutboundSendTracker()
        _outboundTracker = State(initialValue: outboundTrackerLocal)
        _intelligenceSettings = State(initialValue: IntelligenceSettings(defaults: settingsDefaultsLocal))
        _intelligenceService = State(initialValue: IntelligenceService())

        let triageSettingsLocal = TriageSettings(defaults: settingsDefaultsLocal)
        _triageSettings = State(initialValue: triageSettingsLocal)
        let triageCoordinatorLocal = FeedbackTriageCoordinator(
            provider: _intelligenceService.wrappedValue,
            store: TriageVerdictStore(context: ModelContext(container)),
            settings: triageSettingsLocal,
            applier: TaskServiceTriageApplier()
        )
        _triageCoordinator = State(initialValue: triageCoordinatorLocal)

        let settings = NotificationSettings()
        let router = NotificationRouter()
        let notifiedStore = NotifiedIssueStore()
        let service = NotificationService(
            center: UNUserNotificationCenter.current(),
            notifiedStore: notifiedStore,
            settings: settings,
            router: router
        )
        UNUserNotificationCenter.current().delegate = service

        _notificationSettings = State(initialValue: settings)
        _notificationRouter = State(initialValue: router)
        _notificationService = State(initialValue: service)

        let activityLogValue = _activityLog.wrappedValue

        let mirrorLocal = MailToGitHubMirror(
            context: ModelContext(container),
            repoStore: _store.wrappedValue,
            activityLog: activityLogValue,
            poster: GitHubCommentPoster()
        )
        _mirrorHolder = State(initialValue: MailToGitHubMirrorHolder(mirrorLocal))

        let feedbackMirrorLocal = MailToFeedbackMirror(
            context: ModelContext(container),
            productStore: _store.wrappedValue,
            activityLog: activityLogValue
        )
        _feedbackMirrorHolder = State(initialValue: MailToFeedbackMirrorHolder(feedbackMirrorLocal))

        // App Store Connect review registry: one coordinator per product that has ASC configured.
        let ascMirrorStore = AppStoreReviewMirrorStore(context: ModelContext(container))
        _appStoreReviewMirrorStore = State(initialValue: ascMirrorStore)
        let ascRegistry = AppStoreReviewCoordinatorRegistry { cfg in
            let auth = AppStoreConnectAuth(issuerID: cfg.issuerID, keyID: cfg.keyID,
                                           p8PEM: KeychainService.loadASCKeySync(for: cfg.id) ?? "")
            let client = AppStoreConnectClient(auth: auth, activityLog: activityLogValue)
            let owner = cfg.owner; let repo = cfg.repo
            return AppStoreReviewCoordinator(
                config: cfg, client: client, issueWriter: GitHubIssueWriter(),
                commentPoster: GitHubCommentPoster(), mirrorStore: ascMirrorStore,
                tokenLoader: { KeychainService.loadSync(for: ProductConfig(displayName: "", owner: owner, repo: repo)) },
                activityLog: activityLogValue)
        }
        let initialProducts = _store.wrappedValue.repos
        ascRegistry.syncWithProducts(Self.ascConfigs(from: initialProducts, mode: launchMode))
        _appStoreRegistry = State(initialValue: ascRegistry)

        // Feedback-attachment downloader (GitHub issue attachments).
        let feedbackLocalStore = FeedbackAttachmentLocalStore(context: ModelContext(container))
        let snapshot = repoConfigSnapshot
        let feedbackDownloader = FeedbackAttachmentDownloader(
            session: .shared,
            localStore: feedbackLocalStore,
            tokenProvider: { url in
                // Route token lookup by owner/repo parsed from raw.githubusercontent.com URLs.
                guard url.host == "raw.githubusercontent.com" else { return nil }
                let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { return nil }
                let owner = String(parts[0])
                let repo = String(parts[1])
                return snapshot.token(forOwner: owner, repo: repo)
            }
        )
        _feedbackAttachmentDownloaderHolder = State(initialValue: FeedbackAttachmentDownloaderHolder(feedbackDownloader))

        #if canImport(SwiftMail)
        let titlesContainer = container
        let mirrorRef = mirrorLocal
        let feedbackMirrorRef = feedbackMirrorLocal
        let serviceRef = service
        let activityLogRef = activityLogValue
        let registryFactory: (UUID) -> MailSyncCoordinator = { id in
            let provider = IMAPClientProvider(accountStore: mailAccountStoreLocal, accountID: id)
            return MailSyncCoordinator(
                client: provider,
                accountID: id,
                threadStore: threadStoreLocal,
                accountStore: mailAccountStoreLocal,
                settingsStore: mailSettingsStoreLocal,
                localState: localStateStoreLocal,
                activityLog: activityLogRef,
                mirror: mirrorRef,
                feedbackMirror: feedbackMirrorRef,
                notificationService: serviceRef,
                knownIssueTitlesProvider: { @Sendable in
                    await MainActor.run {
                        let ctx = ModelContext(titlesContainer)
                        let cached = (try? ctx.fetch(FetchDescriptor<CachedIssue>())) ?? []
                        return cached.map { (owner: $0.repoOwner, repo: $0.repoName, number: $0.number, title: $0.title) }
                    }
                }
            )
        }
        let registry = MailSyncCoordinatorRegistry(
            accountStore: mailAccountStoreLocal,
            factory: registryFactory
        )
        // Mock mode: no mail registry at all, so no Settings-added account is ever synced, polled
        // or flagged on a real IMAP server (every call site already handles nil).
        if launchMode.runsExternalSources { registry.syncWithAccounts() }
        _coordinatorRegistry = State(initialValue: launchMode.runsExternalSources ? registry : nil)

        // The attachment downloader routes each fetch to the IMAP client of the account that owns
        // the message (its bytes live in THAT account's Sent/INBOX folder); nil → default sender.
        let defaultAccountID = mailAccountStoreLocal.defaultSender?.id ?? UUID()
        let attachmentLocalStore = MailAttachmentLocalStore(context: ModelContext(container))
        let downloader = AttachmentDownloader(
            clientForAccount: { accountID in
                IMAPClientProvider(accountStore: mailAccountStoreLocal, accountID: accountID ?? defaultAccountID)
            },
            localStore: attachmentLocalStore
        )
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(downloader))
        #else
        _coordinatorRegistry = State(initialValue: nil)
        _downloaderHolder = State(initialValue: AttachmentDownloaderHolder(nil))
        #endif

        // GitHub issue loaders: one registry owning the UI's loaders + the 15-min foreground
        // refresh loop, so periodic refreshes land in the loaders the UI actually renders.
        let cacheCtx = _cacheContext.wrappedValue
        // Mock mode: loaders serve the seeded cache (no token, no network), and fake issues
        // never trigger notifications or AI triage.
        let issueRegistry = IssueLoaderRegistry(
            factory: { cfg in IssueLoader(config: cfg, activityLog: activityLogValue, cacheContext: cacheCtx) },
            notificationService: isMock ? nil : service,
            cacheOnly: isMock
        )
        if !isMock {
            issueRegistry.triageSink = { groups in
                await triageCoordinatorLocal.processLoaded(groups)
            }
        }
        _issueLoaderRegistry = State(initialValue: issueRegistry)

        #if os(macOS)
        // Registered here rather than in a view so the CLI channel answers regardless of
        // window state. `respond` gets the same store instances the UI uses, so a reply sent
        // from the CLI is indistinguishable from one sent by hand.
        let replyDeps = CLIRequestHandlers.ReplyDependencies(
            accountStore: mailAccountStoreLocal,
            settingsStore: mailSettingsStoreLocal,
            threadStore: threadStoreLocal,
            tracker: outboundTrackerLocal,
            failureStore: outboundFailuresLocal,
            activityLog: activityLogValue,
            templateStore: replyTemplateStoreLocal,
            mirror: mirrorLocal,
            appStoreMirrorStore: ascMirrorStore,
            appStoreContext: { [registry = ascRegistry] productID in
                await registry.responderContext(productID: productID)
            })
        // Reads go through the app's OWN container. Opening a second one over the same store
        // files (what the CLI process does) from in here would duplicate the whole stack on
        // the main actor once per request.
        let cliContext = ModelContext(container)
        let responder = CLIRequestResponder { request in
            try await CLIRequestHandlers.handle(
                request,
                deps: CLIRequestHandlers.Dependencies(registry: issueRegistry,
                                                      local: cliContext, cloud: cliContext,
                                                      reply: replyDeps))
        }
        if !isMock { responder.start() }
        _cliResponder = State(initialValue: responder)
        // Re-point whatever the user already installed, so a moved or rebuilt app self-heals.
        // Never from a test host: it would re-point (or migrate away) the user's real links in
        // ~/.local/bin and ~/.claude/skills to a throwaway DerivedData build.
        if launchMode == .live { CLIInstaller.refreshInstalledLinks() }

        // App Store builds update through the store, so they never get an updater.
        let updates = launchMode == .live && DistributionFlavor.current.usesInAppUpdater
            ? AppUpdateController(defaults: settingsDefaultsLocal) : nil
        updates?.start()
        _appUpdateController = State(initialValue: updates)
        #endif

        #if os(iOS)
        let driver = iOSBackgroundRefreshDriver(
            registry: issueRegistry,
            settings: settings,
            appStoreRegistry: ascRegistry
        )
        driver.register()
        _iosRefreshDriver = State(initialValue: driver)
        #endif
    }

    /// Injects the full set of shared environment objects into a view. Using one helper
    /// ensures all scenes (main WindowGroup, Activity window, Settings window)
    /// receive an identical, complete environment — no drift, no latent missing-@Environment crash.
    private func sharedEnvironment<V: View>(_ content: V) -> some View {
        content
            .environment(store)
            .environment(syncStatus)
            .environment(activityLog)
            .environment(mailAccountStore)
            .environment(gitHubAccountStore)
            .environment(mailSettingsStore)
            .environment(threadStore)
            .environment(replyTemplateStore)
            .environment(outboundTracker)
            .environment(outboundFailures)
            .environment(settingsNavigation)
            .environment(intelligenceSettings)
            .environment(intelligenceService)
            .environment(triageSettings)
            .environment(triageCoordinator)
            .environment(notificationSettings)
            .environment(notificationRouter)
            .environment(downloaderHolder)
            .environment(\.mailSyncCoordinatorRegistry, coordinatorRegistry)
            .environment(mirrorHolder)
            .environment(mailLocalStateStore)
            // nil in mock mode: RootView's backlog snapshot would otherwise write mock repo keys
            // into the real UserDefaults / NotifiedIssueStore (this also hides the Notifications pane).
            .environment(\.notificationService, isMockDataMode ? nil : notificationService)
            .environment(appStoreRegistry)
            .environment(mailDraftStore)
            .environment(quickLook)
            .environment(thumbnailCache)
            .environment(feedbackAttachmentDownloaderHolder)
            .environment(\.isMockDataMode, isMockDataMode)
            #if os(macOS)
            .environment(\.appUpdateController, appUpdateController)
            #endif
            // @AppStorage keys (e.g. `summary.collapsed.*`) stay in the mock suite in mock mode.
            .defaultAppStorage(settingsDefaults)
            #if DEBUG
            .environment(debugSettings)
            #endif
    }

    var body: some Scene {
        WindowGroup {
            sharedEnvironment(
                RootView(store: store, seenStore: seenStore, cacheContext: cacheContext, versionStore: versionStore, filterStore: filterStore, issueLoaderRegistry: issueLoaderRegistry, appStoreReviewMirrorStore: appStoreReviewMirrorStore)
                    #if !os(macOS)
                    .overlay(QuickLookHost())
                    #endif
            )
                #if DEBUG
                .screenshotMode()
                #endif
                #if os(macOS)
                .updateReadyAlert(appUpdateController)
                #endif
                .task { if !isMockDataMode { await notificationService.requestAuthorizationIfNeeded() } }
                .task(id: store.repos.map(\.id)) {
                    repoConfigSnapshot.update(store.repos)
                    appStoreRegistry.syncWithProducts(Self.ascConfigs(from: store.repos, mode: isMockDataMode ? .mock : .live))
                }
                .onAppear {
                    // Mock mode: the mail registry is nil and the App Store registry is given no
                    // configs, so nothing would poll anyway; skip the start calls too.
                    if !isMockDataMode {
                        #if canImport(SwiftMail)
                        coordinatorRegistry?.start()
                        #endif
                        appStoreRegistry.start()
                    }
                    issueLoaderRegistry.start()
                }
                #if os(iOS)
                .onChange(of: notificationSettings.isEnabled) { _, isOn in
                    if isOn { iosRefreshDriver.scheduleNextRefresh() } else { iosRefreshDriver.cancelPending() }
                }
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorRegistry?.pollNow() }
                    }
                    #endif
                    if phase == .active {
                        Task { await appStoreRegistry.pollNow() }
                        Task { await issueLoaderRegistry.pollIfStale() }
                    }
                    if phase == .background { iosRefreshDriver.scheduleNextRefresh() }
                }
                #elseif os(macOS)
                .onChange(of: scenePhase) { _, phase in
                    #if canImport(SwiftMail)
                    if phase == .active {
                        Task { await coordinatorRegistry?.pollNow() }
                    }
                    #endif
                    if phase == .active {
                        Task { await appStoreRegistry.pollNow() }
                        Task { await issueLoaderRegistry.pollIfStale() }
                    }
                }
                #endif
        }
        .modelContainer(container)
        #if os(macOS)
        .commands {
            CommandGroup(after: .appInfo) {
                if let appUpdateController {
                    CheckForUpdatesCommand(updates: appUpdateController, navigation: settingsNavigation)
                }
            }
            CommandGroup(after: .windowList) {
                ActivityMenuCommand()
            }
            // Replace the system Settings… menu item so Cmd-, opens our
            // standalone Window scene (Settings { } scene's resizability
            // is fundamentally restricted; a regular Window resizes normally).
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
        }
        #endif
        #if os(macOS)
        Window("Activity", id: "activity") {
            ActivityWindow()
                .environment(activityLog)
        }
        Window("Settings", id: "settings") {
            sharedEnvironment(SettingsView(store: store))
                #if DEBUG
                .screenshotMode(sizeKey: "LLSettingsWindowSize")
                #endif
        }
        .defaultSize(width: 720, height: 620)
        .windowResizability(.contentMinSize)
        #endif
    }
}

#if os(macOS)
/// "Settings…" menu entry that opens our Window-scene-based Settings, with the
/// standard Cmd-, shortcut. We can't use SettingsLink because it's tied to the
/// Settings { } scene; instead we drive the openWindow environment action.
private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
#endif

// MARK: - EnvironmentKey for MailSyncCoordinatorRegistry

private struct MailSyncCoordinatorRegistryKey: EnvironmentKey {
    static let defaultValue: MailSyncCoordinatorRegistry? = nil
}

extension EnvironmentValues {
    var mailSyncCoordinatorRegistry: MailSyncCoordinatorRegistry? {
        get { self[MailSyncCoordinatorRegistryKey.self] }
        set { self[MailSyncCoordinatorRegistryKey.self] = newValue }
    }
}

#if os(macOS)
private struct ActivityMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Activity") {
            openWindow(id: "activity")
        }
        .keyboardShortcut("0", modifiers: [.command, .option])
    }
}
#endif

// MARK: - Launch mode & container

extension LoveLetterApp {
    /// Which data stack this process runs on. `.mock` is only ever produced in DEBUG builds.
    enum LaunchMode: Equatable {
        case testing, mock, live

        /// False only in mock mode: no mail sync, no App Store polling, no Keychain access.
        var runsExternalSources: Bool { self != .mock }
    }

    /// Process-wide switches that must be set before any store or view can touch the Keychain.
    /// Mock mode makes Keychain reads and writes no-ops so nothing done against fake products can
    /// read or change real secrets.
    static func applySideEffectPolicy(for mode: LaunchMode) {
        KeychainService.accessSuppressed = !mode.runsExternalSources
    }

    #if DEBUG
    /// Throwaway defaults suite for settings changed while running on mock data.
    static let mockSettingsSuiteName = "debug.mock"
    #endif

    /// Where app settings (triage, intelligence, `@AppStorage`) persist. Mock mode gets a
    /// throwaway suite, cleared at every launch, so e.g. setting triage to "Fully automatic"
    /// against mock data can't auto-create tasks on real repos at the next live launch.
    /// `DebugSettings` always uses `.standard`, so the mock toggle can still be turned off.
    static func settingsDefaults(for mode: LaunchMode) -> UserDefaults {
        #if DEBUG
        if mode == .mock, let suite = UserDefaults(suiteName: mockSettingsSuiteName) {
            suite.removePersistentDomain(forName: mockSettingsSuiteName)
            return suite
        }
        #endif
        return .standard
    }

    /// The products the App Store review registry should poll: those with all three ASC fields.
    /// Empty in mock mode, so an App Store source set up on a mock product never reaches ASC.
    static func ascConfigs(from products: [ProductConfig], mode: LaunchMode) -> [ASCProductConfig] {
        guard mode.runsExternalSources else { return [] }
        return products.compactMap {
            ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                  issuerID: $0.appStoreIssuerID, keyID: $0.appStoreKeyID,
                                  appAppleID: $0.appStoreAppAppleID)
        }
    }

    /// Precedence: test host → mock data (DEBUG toggle, read once at launch) → real stores.
    static func resolveLaunchMode(isTesting: Bool) -> LaunchMode {
        if isTesting { return .testing }
        #if DEBUG
        if DebugSettings.isMockDataActiveAtLaunch { return .mock }
        #endif
        return .live
    }

    /// `.testing` and `.mock` share one in-memory, CloudKit-free configuration, so mock mode can
    /// never open, read or sync the real stores. `.live` is the production two-store layout. It's
    /// kept verbatim because the CLI's read-only container mirrors it exactly.
    static func makeContainer(mode: LaunchMode) throws -> ModelContainer {
        switch mode {
        case .testing, .mock:
            // In-process test host / mock data: single in-memory config, no CloudKit validation.
            let testConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            return try ModelContainer(
                for: Product.self, Repo.self, SeenIssue.self, MailAccount.self,
                    GitHubAccount.self,
                    MailSettings.self,
                    MailThread.self, MailMessage.self, MailAttachment.self,
                    IssueTranslation.self, IssueSummaryCache.self,
                    ProjectVersion.self, SentReleaseNotification.self,
                    CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                    RepoFetchState.self, FeedbackAttachmentLocal.self,
                    ReplyTemplate.self,
                    RepoFilterPreference.self,
                    AppStoreReviewMirror.self,
                    TriageVerdictRecord.self,
                configurations: testConfig
            )
        case .live:
            let cloudSchema = Schema([Product.self, Repo.self, SeenIssue.self, MailAccount.self, GitHubAccount.self, MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self, IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self, SentReleaseNotification.self, ReplyTemplate.self, RepoFilterPreference.self, AppStoreReviewMirror.self])
            let localSchema = Schema([CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self, RepoFetchState.self, FeedbackAttachmentLocal.self, TriageVerdictRecord.self])
            let cloudConfig = ModelConfiguration(
                "cloud",
                schema: cloudSchema,
                // Persisted under the pre-rename name; do not change.
                cloudKitDatabase: .private("iCloud.com.amirhayek.AppFeedback")
            )
            let localConfig = ModelConfiguration("local", schema: localSchema, cloudKitDatabase: .none)
            return try ModelContainer(
                for: Product.self, Repo.self, SeenIssue.self, MailAccount.self,
                    GitHubAccount.self,
                    MailSettings.self,
                    MailThread.self, MailMessage.self, MailAttachment.self,
                    IssueTranslation.self, IssueSummaryCache.self,
                    ProjectVersion.self, SentReleaseNotification.self,
                    CachedIssue.self, MailAttachmentLocal.self, MailAccountLocalState.self,
                    RepoFetchState.self, FeedbackAttachmentLocal.self,
                    ReplyTemplate.self,
                    RepoFilterPreference.self,
                    AppStoreReviewMirror.self,
                    TriageVerdictRecord.self,
                configurations: cloudConfig, localConfig
            )
        }
    }

    #if DEBUG
    /// Seeds the in-memory mock container. Loud on failure (DEBUG only); the app still launches
    /// with whatever was saved.
    static func seedMockData(into container: ModelContainer) {
        do {
            try MockDataSeeder.seed(into: ModelContext(container))
        } catch {
            Logger().error("Mock data seeding failed: \(error.localizedDescription, privacy: .public)")
            assertionFailure("Mock data seeding failed: \(error)")
        }
    }
    #endif
}
