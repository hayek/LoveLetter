# Debug Settings + Mock Data Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A DEBUG-only "Debug" settings pane whose "Mock data" toggle makes the app launch into a seeded, in-memory world of fake products, feedback, tasks, and releases. Real stores, Keychain tokens, and the network are never touched in that mode.

**Architecture:** `DebugSettings` persists the toggle in `UserDefaults`, and the process reads it once at launch. `LoveLetterApp.init` resolves a `LaunchMode` (`.testing` / `.mock` / `.live`). `.mock` builds the same in-memory container the test host uses, seeds it with `MockDataSeeder` before any store is built, and turns off every side-effect source (migrations, on-disk logs, mail/App Store pollers, CLI responder, notifications, triage). `IssueLoaderRegistry(cacheOnly: true)` serves loaders from the seeded cache with no token lookup. `\.isMockDataMode` drives a "MOCK DATA" badge.

**Tech Stack:** SwiftUI, SwiftData, Observation, LoveLetterCore (SDK body formatter/parser), XCTest + Swift Testing, xcodegen, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-09-23-debug-mock-data-design.md`

## Global Constraints

- **Worktree only:** all work happens in `/Users/amir/Developer/LoveLetter-mock-data` (branch `feat/debug-mock-data`). Never touch `/Users/amir/Developer/LoveLetter`, which holds the user's uncommitted WIP.
- **DEBUG fencing:** all new feature code is wrapped in `#if DEBUG`. A few things are allowed in every build:
  - the `EnvironmentValues.isMockDataMode` key (default `false`),
  - the `SettingsSelection.debug` enum case,
  - the `LoveLetterApp.LaunchMode.mock` case, which only DEBUG code can produce,
  - the `MockDataBadgeOverlay` type, whose body is `content` in Release.
- UserDefaults key: `debug.useMockData`.
- Mock GitHub owner: `mock-studio`. Mock reporter emails use `@example.com` only.
- Mock products have **no** ASC credentials, no feedback inbox, no connected repo, and no attachments. The App Store / mail / attachment pipelines must have nothing to act on.
- **Container construction is moved verbatim.** Keep the `ModelContainer(for: A.self, B.self, …, configurations:)` variadic form and the exact type lists and config names. The macOS CLI opens a read-only second container that must mirror the live one exactly.
- Deployment targets are iOS/macOS 27.0 (Xcode 27). Swift language mode is 5.9. Tests may use XCTest or Swift Testing; match the file you touch.
- **Build/test ground truth is `xcodebuild`**, run from `/Users/amir/Developer/LoveLetter-mock-data`. Don't rely on zcode.
  - Targeted macOS test: `xcodebuild test -project LoveLetter.xcodeproj -scheme LoveLetter_macOS -destination 'platform=macOS' -only-testing:LoveLetterTests_macOS/<TestClass> 2>&1 | grep -E "error:|failed|passed|✘|✔|\*\* TEST" | tail -40`
  - macOS build: `xcodebuild build -project LoveLetter.xcodeproj -scheme LoveLetter_macOS -destination 'platform=macOS' 2>&1 | grep -E "error:|\*\* BUILD" | tail -20`
  - iOS build: `xcodebuild build -project LoveLetter.xcodeproj -scheme LoveLetter_iOS -destination 'generic/platform=iOS Simulator' 2>&1 | grep -E "error:|\*\* BUILD" | tail -20`
- **CodeSign stale `.cstemp` flake:** if a build fails in CodeSign mentioning `.cstemp`, run `rm -rf ~/Library/Developer/Xcode/DerivedData/LoveLetter-*/Build/Products/Debug/LoveLetter.app` and rerun. It isn't a code problem.
- **Known pre-existing failures (not regressions):**
  - about 11 failures in `KeychainServicePerAccountTests` and `GitHubAccountStoreTests` (the test host has no Keychain),
  - an intermittent SwiftData "No eligible connection" test-host crash. Rerun before blaming a change.
- **Test host shares the app's `UserDefaults.standard` domain.** Tests must never write `debug.useMockData` to `.standard`; use a named suite.
- **xcodegen recipe (run after adding any new file):**
  1. `cd /Users/amir/Developer/LoveLetter-mock-data && xcodegen generate`
  2. Undo xcodegen's known baseline drift. Even on a clean tree it rewrites 4 signing/project hunks. This script was verified to round-trip a clean tree to a zero diff. Save it once as `$TMPDIR/restore-pbxproj.py` and run `python3 $TMPDIR/restore-pbxproj.py` after every `xcodegen generate`:
     ```python
     import pathlib
     p = pathlib.Path('/Users/amir/Developer/LoveLetter-mock-data/LoveLetter.xcodeproj/project.pbxproj')
     s = p.read_text()
     s = s.replace('CODE_SIGN_IDENTITY = "iPhone Developer";', 'CODE_SIGN_IDENTITY = "Apple Development";')
     s = s.replace('PRODUCT_NAME = LoveLetter;\n\t\t\t\tSDKROOT = iphoneos;', 'PRODUCT_NAME = LoveLetter;\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = "";\n\t\t\t\tSDKROOT = iphoneos;')
     s = s.replace('{isa = PBXFileReference; includeInIndex = 0; lastKnownFileType = wrapper.application; path = LoveLetter.app; sourceTree = BUILT_PRODUCTS_DIR; };', '{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = LoveLetter.app; sourceTree = BUILT_PRODUCTS_DIR; };')
     s = s.replace('\t\t\t\t\t81DD6B420B4D374B103B70A3 = {\n\t\t\t\t\t\tDevelopmentTeam = Q7U5734Q3T;\n\t\t\t\t\t\tProvisioningStyle = Automatic;\n\t\t\t\t\t};\n', '')
     p.write_text(s)
     ```
  3. Check what's left: `git diff LoveLetter.xcodeproj/project.pbxproj | grep -E '^[-+]' | grep -vE '^(\+\+\+|---)'`. The only remaining lines should add `PBXFileReference` / `PBXBuildFile` / group / sources-phase entries for your new files. If any `CODE_SIGN*`, `DEVELOPMENT_TEAM`, `PROVISIONING*`, or `TargetAttributes` line still shows as changed, restore it by hand.
  4. `git status --short` must show no `.xcscheme` changes. If it does, run `git checkout LoveLetter.xcodeproj/xcshareddata`.
- **Commits:** stage only the files the task lists, plus `LoveLetter.xcodeproj/project.pbxproj` when files were added. Never use `git add -A` or `git add .`. End every commit message with:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

- **Refresh paths in mock mode** (pull-to-refresh `loadAll(fullReconcile: true)`, the 15-minute `refreshTick()`, scene-activation `pollIfStale()`/`retryStuck()`, `load(productID:)` after a task write) must never call the token provider or the network. They only re-read the cache. Covered by Task 2 tests.
- **A product with an empty cache in cache-only mode** (for example, one the user adds while in mock mode) must land in `.loaded([])`, not stay `.idle`. `.idle` renders an endless "Loading…" spinner in `IssueListView`. Covered by Task 2.
- **"Done" mock tasks must be visible.** The UI only reads OPEN cached rows, so a closed task would silently vanish and the Done status would never appear. Mock done tasks are stored OPEN with the `status:done` label. Covered by Task 3's cache-read test.
- **Pending vs. active toggle:** turning mock on then off again before relaunching must not show "Relaunch to apply". Launching in mock mode and turning it off must show it. Covered by Task 1.
- **Mock products must give the real pipelines nothing to do:** no ASC credentials, no feedback inbox, no connected repo, no attachment URLs, no non-`example.com` emails. Seeding twice must not duplicate data. Covered by Task 3.

---

### Task 1: `DebugSettings` (persisted toggle + launch snapshot)

**Files:**
- Create: `LoveLetter/Services/Debug/DebugSettings.swift`
- Test: `LoveLetterTests/DebugSettingsTests.swift`
- Modify (via xcodegen): `LoveLetter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: nothing.
- Produces (all `#if DEBUG`):
  - `@Observable @MainActor final class DebugSettings`
  - `static let useMockDataKey = "debug.useMockData"`
  - `static func readUseMockData(from: UserDefaults) -> Bool`
  - `static let isMockDataActiveAtLaunch: Bool`
  - `init(defaults: UserDefaults = .standard, mockDataActiveAtLaunch: Bool? = nil)`
  - `var useMockData: Bool` (persists on set)
  - `let mockDataActiveAtLaunch: Bool`
  - `var needsRelaunch: Bool`

- [ ] **Step 1: Write the failing tests.** Create `LoveLetterTests/DebugSettingsTests.swift`:

```swift
#if DEBUG
import XCTest
@testable import LoveLetter

@MainActor
final class DebugSettingsTests: XCTestCase {
    // Never `.standard`: the test host shares the real app's defaults domain.
    private let suiteName = "DebugSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_default_isOff() {
        XCTAssertFalse(DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false).useMockData)
    }

    func test_useMockData_persistsUnderDebugKey() {
        DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false).useMockData = true
        XCTAssertTrue(defaults.bool(forKey: "debug.useMockData"))
        XCTAssertTrue(DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false).useMockData)
    }

    func test_readUseMockData_readsTheKey() {
        XCTAssertFalse(DebugSettings.readUseMockData(from: defaults))
        defaults.set(true, forKey: DebugSettings.useMockDataKey)
        XCTAssertTrue(DebugSettings.readUseMockData(from: defaults))
    }

    func test_needsRelaunch_whenPendingDiffersFromActive() {
        let s = DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false)
        XCTAssertFalse(s.needsRelaunch)
        s.useMockData = true
        XCTAssertTrue(s.needsRelaunch)
    }

    func test_togglingBackBeforeRelaunch_clearsNeedsRelaunch() {
        let s = DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false)
        s.useMockData = true
        s.useMockData = false
        XCTAssertFalse(s.needsRelaunch)
    }

    func test_launchedInMockMode_turningOffNeedsRelaunch() {
        defaults.set(true, forKey: DebugSettings.useMockDataKey)
        let s = DebugSettings(defaults: defaults, mockDataActiveAtLaunch: true)
        XCTAssertTrue(s.useMockData)
        XCTAssertFalse(s.needsRelaunch)
        s.useMockData = false
        XCTAssertTrue(s.needsRelaunch)
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project and verify the test fails.** Run the xcodegen recipe from Global Constraints, then the targeted test command with `<TestClass>` = `DebugSettingsTests`.
  Expected: BUILD FAILED, `cannot find 'DebugSettings' in scope`.

- [ ] **Step 3: Implement.** Create `LoveLetter/Services/Debug/DebugSettings.swift`:

```swift
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
```

- [ ] **Step 4: Run the test and verify it passes.** Run the same targeted command. Expected: all 6 `DebugSettingsTests` pass.

- [ ] **Step 5: Commit.**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
git add LoveLetter/Services/Debug/DebugSettings.swift LoveLetterTests/DebugSettingsTests.swift LoveLetter.xcodeproj/project.pbxproj
git commit -m "feat(debug): persisted mock-data toggle with launch snapshot

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Cache-only issue loading

**Files:**
- Modify: `LoveLetter/Services/IssueLoader.swift` (add `loadCachedOnly()` next to `purgeFromCache`, in `// MARK: - Cache`)
- Modify: `LoveLetter/Services/IssueLoaderRegistry.swift` (the `init` and `private func load(_:fullReconcile:)`)
- Test: `LoveLetterTests/IssueLoaderRegistryTests.swift` (extend)
- Test: `LoveLetterTests/IssueLoaderTests.swift` (extend)

**Interfaces:**
- Consumes: the existing `IssueLoader.loadOpenIssuesFromCache()` (private, same file).
- Produces:
  - `IssueLoader.loadCachedOnly()`: sets `state = .loaded(openCachedIssues, Date())`, even when the cache is empty.
  - `IssueLoaderRegistry.init(factory:tokenProvider:notificationService:clock:cacheOnly:)`, with a new trailing `cacheOnly: Bool = false`. When `true`, every load path calls `loadCachedOnly()` and never calls `tokenProvider`.

- [ ] **Step 1: Write the failing tests.**

Append to `LoveLetterTests/IssueLoaderTests.swift`, inside the class, before the closing brace. It uses that file's existing `context` and `makeLoader()`:

```swift
    // MARK: - Cache-only (mock data mode)

    func test_loadCachedOnly_servesOpenRowsWithoutNetwork() {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("cache-only load must not touch the network")
            throw URLError(.notConnectedToInternet)
        }
        let open = CachedIssue(repoOwner: "org", repoName: "feedback", number: 1, title: "Open",
                               createdAt: Date(timeIntervalSince1970: 1_750_000_000), rawBody: "",
                               appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
                               issueDescription: "d")
        let closed = CachedIssue(repoOwner: "org", repoName: "feedback", number: 2, title: "Closed",
                                 createdAt: Date(timeIntervalSince1970: 1_750_000_000), state: .closed,
                                 rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil,
                                 email: nil, issueDescription: "d")
        context.insert(open); context.insert(closed)
        try! context.save()

        let loader = makeLoader()
        loader.loadCachedOnly()

        guard case .loaded(let issues, let date) = loader.state else { return XCTFail("expected .loaded, got \(loader.state)") }
        XCTAssertEqual(issues.map(\.number), [1])
        XCTAssertFalse(loader.isShowingCachedData, "cache-only is the final state, not the stale-cache sentinel")
        XCTAssertNotEqual(date, Date(timeIntervalSince1970: 0))
    }

    func test_loadCachedOnly_emptyCacheIsLoadedNotIdle() {
        let loader = makeLoader()
        loader.loadCachedOnly()
        guard case .loaded(let issues, _) = loader.state else { return XCTFail("empty cache must be .loaded([]) so the list isn't an endless spinner") }
        XCTAssertTrue(issues.isEmpty)
    }
```

Append to `LoveLetterTests/IssueLoaderRegistryTests.swift`, inside the class. Also add `import SwiftData` below `import XCTest` at the top of that file:

```swift
    // MARK: cacheOnly (mock data mode)

    private func makeCacheOnlyRegistry(cachedNumbers: [Int], repo: String) throws -> (IssueLoaderRegistry, ModelContainer) {
        let schema = Schema([CachedIssue.self, RepoFetchState.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for n in cachedNumbers {
            context.insert(CachedIssue(repoOwner: "o", repoName: repo, number: n, title: "Cached \(n)",
                                       createdAt: Self.epoch, rawBody: "", appName: nil, appVersion: nil,
                                       device: nil, osVersion: nil, email: nil, issueDescription: "d"))
        }
        try context.save()
        MockURLProtocol.requestHandler = { _ in
            XCTFail("cache-only registry must not touch the network")
            throw URLError(.notConnectedToInternet)
        }
        let registry = IssueLoaderRegistry(
            factory: { IssueLoader(config: $0, session: .mock, cacheContext: context) },
            tokenProvider: { _ in
                XCTFail("cache-only registry must never look up a token")
                return nil
            },
            clock: { IssueLoaderRegistryTests.epoch },
            cacheOnly: true)
        return (registry, container)
    }

    func testCacheOnlyLoadAllServesCacheWithoutToken() async throws {
        let (registry, container) = try makeCacheOnlyRegistry(cachedNumbers: [3, 7], repo: "a")
        _ = container   // keep the store alive for the test's duration
        let a = makeConfig("a")
        registry.syncWithProducts([a])
        await registry.loadAll(fullReconcile: true)   // the pull-to-refresh path
        guard case .loaded(let issues, _)? = registry.loaders[a.id]?.state else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(Set(issues.map(\.number)), [3, 7])
        XCTAssertEqual(registry.lastRefreshAt, Self.epoch)
    }

    func testCacheOnlyEmptyCacheLandsLoadedEmpty() async throws {
        let (registry, container) = try makeCacheOnlyRegistry(cachedNumbers: [], repo: "a")
        _ = container
        let a = makeConfig("a")
        registry.syncWithProducts([a])
        await registry.loadAll()
        guard case .loaded(let issues, _)? = registry.loaders[a.id]?.state else {
            return XCTFail("empty cache must be .loaded([]), not .idle (endless spinner)")
        }
        XCTAssertTrue(issues.isEmpty)
    }

    func testCacheOnlyRefreshTickAndSingleProductLoadNeverAskForToken() async throws {
        let (registry, container) = try makeCacheOnlyRegistry(cachedNumbers: [1], repo: "a")
        _ = container
        let a = makeConfig("a")
        registry.syncWithProducts([a])
        await registry.refreshTick()
        await registry.load(productID: a.id, fullReconcile: true)
        await registry.pollIfStale()
        guard case .loaded(let issues, _)? = registry.loaders[a.id]?.state else { return XCTFail("expected .loaded") }
        XCTAssertEqual(issues.map(\.number), [1])
    }
```

- [ ] **Step 2: Run the tests and verify they fail.** Targeted command with `-only-testing:LoveLetterTests_macOS/IssueLoaderRegistryTests -only-testing:LoveLetterTests_macOS/IssueLoaderTests`.
  Expected: BUILD FAILED with `value of type 'IssueLoader' has no member 'loadCachedOnly'` and `extra argument 'cacheOnly' in call`.

- [ ] **Step 3: Implement `IssueLoader.loadCachedOnly()`.** In `LoveLetter/Services/IssueLoader.swift`, add this directly above `func purgeFromCache(number: Int) {`:

```swift
    /// Mock-data mode: serve the locally seeded cache as the final state. No token, no network.
    /// Stamped with `Date()` (not the epoch sentinel) because there is no fresher data coming,
    /// and an empty cache still becomes `.loaded([])` so the list never spins forever.
    func loadCachedOnly() {
        state = .loaded(loadOpenIssuesFromCache(), Date())
    }

```

- [ ] **Step 4: Implement `cacheOnly` in the registry.** In `LoveLetter/Services/IssueLoaderRegistry.swift`:

Add a stored property below `private let clock: () -> Date`:

```swift
    /// Mock-data mode: loaders only re-read the seeded local cache. No Keychain, no network.
    private let cacheOnly: Bool
```

Replace the init signature and body with:

```swift
    init(
        factory: @escaping (ProductConfig) -> IssueLoader,
        tokenProvider: @escaping @Sendable (ProductConfig) async -> String? = { await KeychainService.load(for: $0) },
        notificationService: NotificationService? = nil,
        clock: @escaping () -> Date = { Date() },
        cacheOnly: Bool = false
    ) {
        self.factory = factory
        self.tokenProvider = tokenProvider
        self.notificationService = notificationService
        self.clock = clock
        self.cacheOnly = cacheOnly
    }
```

At the very top of `private func load(_ repos: [ProductConfig], fullReconcile: Bool) async {`, before `await withTaskGroup`, insert:

```swift
        if cacheOnly {
            for repo in repos { loaders[repo.id]?.loadCachedOnly() }
            return
        }
```

- [ ] **Step 5: Run the tests and verify they pass.** Same targeted command. Expected: the 5 new tests pass and the existing `IssueLoaderRegistryTests` / `IssueLoaderTests` stay green.

- [ ] **Step 6: Commit.**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
git add LoveLetter/Services/IssueLoader.swift LoveLetter/Services/IssueLoaderRegistry.swift LoveLetterTests/IssueLoaderRegistryTests.swift LoveLetterTests/IssueLoaderTests.swift
git commit -m "feat(issues): cache-only loading mode for the issue loader registry

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `MockDataSeeder` + catalog

**Files:**
- Create: `LoveLetter/Services/Debug/MockDataSeeder.swift` (seeding engine)
- Create: `LoveLetter/Services/Debug/MockDataCatalog.swift` (the demo content, as data)
- Test: `LoveLetterTests/MockDataSeederTests.swift`
- Modify (via xcodegen): `LoveLetter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes:
  - `IssueLoader.loadCachedOnly()` (Task 2, used by the tests)
  - `IssueLoader.decodePageForTesting(data:owner:repo:)` (existing, `#if DEBUG`)
  - `CachedIssue.from(_:repoOwner:repoName:)`
  - `TaskService.body(prose:feedbackRefs:)` / `TaskService.labels(status:priority:)` (nonisolated statics)
  - `IssueBodyFormatter.format(report:deviceInfo:)` / `.labels(for:)` / `.sourceMetadataBlock(...)` (LoveLetterCore)
  - `AppStoreReviewSynthesizer.title/body/labels(for:)`
  - `MailToFeedbackMirror.issueTitle(subject:)`
  - `MailToGitHubMirror.redact(_:)`
  - `ProjectVersion.derivedState(anyTaskStarted:)`
- Produces (all `#if DEBUG`):
  - `@MainActor enum MockDataSeeder`
  - `static let owner = "mock-studio"`
  - `static func seed(into: ModelContext, now: Date = Date()) throws`, a no-op if any `Product` already exists
  - `static func issues(for: ProductSpec, now: Date) throws -> [FeedbackIssue]`
  - `static let products: [ProductSpec]`
  - the nested spec types `Origin`, `FeedbackSpec`, `TaskSpec`, `VersionSpec`, `ProductSpec`

Key facts the implementer needs:
- The task label is `LoveLetterLabels.task` = `"appfeedback:task"`. Status labels are `status:todo|in-progress|done` and priority labels are `priority:low|med|high`.
- Feedback refs live in the task body block `<!-- appfeedback:addresses -->\nAddresses: #1, #4\n<!-- /appfeedback:addresses -->`. `TaskService.body(prose:feedbackRefs:)` writes that block.
- A version's derived state is computed as follows:
  - `released`: `releasePublished`.
  - `wip`: any task whose `milestoneTitle == version.name` is `.inProgress` or completed.
  - `new`: anything else.
- `IssueLoader` only ever reads **OPEN** cached rows, so every mock row, including Done tasks, is `state: OPEN`.

- [ ] **Step 1: Write the failing tests.** Create `LoveLetterTests/MockDataSeederTests.swift`:

```swift
#if DEBUG
import XCTest
import SwiftData
@testable import LoveLetter

@MainActor
final class MockDataSeederTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var containers: [ModelContainer] = []   // keep stores alive for the test's duration

    override func tearDown() {
        containers = []
        super.tearDown()
    }

    private func makeSeededContext() throws -> ModelContext {
        let schema = Schema([Product.self, CachedIssue.self, ProjectVersion.self, SeenIssue.self,
                             SentReleaseNotification.self, RepoFetchState.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        containers.append(container)
        let context = ModelContext(container)
        try MockDataSeeder.seed(into: context, now: Self.now)
        return context
    }

    private func products(_ context: ModelContext) throws -> [Product] {
        try context.fetch(FetchDescriptor<Product>(sortBy: Product.sidebarOrder))
    }

    /// Reads a product exactly the way the app does in mock mode: through a cache-only loader.
    private func openIssues(_ product: Product, _ context: ModelContext) -> [FeedbackIssue] {
        let config = ProductConfig(id: product.id, displayName: product.displayName, owner: product.owner, repo: product.repo)
        let loader = IssueLoader(config: config, cacheContext: context)
        loader.loadCachedOnly()
        guard case .loaded(let issues, _) = loader.state else { return [] }
        return issues
    }

    func testSeedsThreeMockProductsWithNoRealSourceWiring() throws {
        let context = try makeSeededContext()
        let all = try products(context)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.repo)).count, 3)
        for p in all {
            XCTAssertEqual(p.owner, "mock-studio")
            XCTAssertNotNil(p.colorHex)
            XCTAssertNil(p.appStoreIssuerID); XCTAssertNil(p.appStoreKeyID); XCTAssertNil(p.appStoreAppAppleID)
            XCTAssertNil(p.feedbackInboxAccountID)
            XCTAssertNil(p.connectedRepoOwner); XCTAssertNil(p.connectedRepoName)
        }
        XCTAssertEqual(all.map(\.sortOrder), [0, 1, 2])
    }

    func testEveryProductHasFeedbackTasksAndThreeVersions() throws {
        let context = try makeSeededContext()
        let versions = try context.fetch(FetchDescriptor<ProjectVersion>())
        for p in try products(context) {
            let issues = openIssues(p, context)
            let feedback = issues.filter { !TaskItem.isTask($0) }
            let tasks = issues.filter(TaskItem.isTask)
            XCTAssertTrue((6...10).contains(feedback.count), "\(p.repo): \(feedback.count) feedback")
            XCTAssertTrue((3...6).contains(tasks.count), "\(p.repo): \(tasks.count) tasks")
            XCTAssertGreaterThanOrEqual(versions.filter { $0.repoName == p.repo }.count, 3)
            XCTAssertEqual(Set(issues.map(\.number)).count, issues.count, "\(p.repo): issue numbers unique")
            XCTAssertTrue(issues.allSatisfy { $0.attachments.isEmpty }, "no attachment URLs → no downloader traffic")
        }
    }

    func testEveryTaskStatusAndPriorityIsVisibleThroughTheOpenOnlyCache() throws {
        let context = try makeSeededContext()
        for p in try products(context) {
            let tasks = openIssues(p, context).filter(TaskItem.isTask).map(TaskItem.init(issue:))
            XCTAssertEqual(Set(tasks.map(\.displayStatus)), Set(TaskStatus.allCases), "\(p.repo) statuses")
            XCTAssertEqual(Set(tasks.map(\.priority)), Set(TaskPriority.allCases), "\(p.repo) priorities")
        }
    }

    func testTaskRefsAndMilestonesResolveWithinTheirProduct() throws {
        let context = try makeSeededContext()
        let versions = try context.fetch(FetchDescriptor<ProjectVersion>())
        for p in try products(context) {
            let issues = openIssues(p, context)
            let feedbackNumbers = Set(issues.filter { !TaskItem.isTask($0) }.map(\.number))
            let versionNames = Set(versions.filter { $0.repoName == p.repo }.map(\.name))
            for task in issues.filter(TaskItem.isTask).map(TaskItem.init(issue:)) {
                XCTAssertFalse(task.feedbackRefs.isEmpty, "#\(task.number) has refs")
                XCTAssertTrue(Set(task.feedbackRefs).isSubset(of: feedbackNumbers), "#\(task.number) refs \(task.feedbackRefs)")
                if let m = task.milestoneTitle { XCTAssertTrue(versionNames.contains(m), "#\(task.number) milestone \(m)") }
            }
        }
    }

    func testEachProductCoversNewWipAndReleasedVersions() throws {
        let context = try makeSeededContext()
        let versions = try context.fetch(FetchDescriptor<ProjectVersion>())
        for p in try products(context) {
            let tasks = openIssues(p, context).filter(TaskItem.isTask).map(TaskItem.init(issue:))
            let states = Set(versions.filter { $0.repoName == p.repo }.map { v in
                v.derivedState(anyTaskStarted: tasks.contains {
                    $0.milestoneTitle == v.name && ($0.status == .inProgress || $0.isCompleted)
                })
            })
            XCTAssertEqual(states, [.new, .wip, .released], p.repo)
            for v in versions where v.releasePublished {
                XCTAssertNotNil(v.releasedAt); XCTAssertNotNil(v.releaseTag); XCTAssertFalse(v.changelog.isEmpty)
            }
        }
    }

    func testSourcesRatingsAndReporterDomains() throws {
        let context = try makeSeededContext()
        for p in try products(context) {
            let feedback = openIssues(p, context).filter { !TaskItem.isTask($0) }
            XCTAssertEqual(Set(feedback.map(\.source)), Set(FeedbackSource.allCases), "\(p.repo) sources")
            for f in feedback where f.source == .appStore {
                XCTAssertNotNil(f.rating); XCTAssertTrue((1...5).contains(f.rating ?? 0))
                XCTAssertNotNil(f.territory)
            }
            for f in feedback where f.source == .sdk {
                XCTAssertNotNil(f.device); XCTAssertNotNil(f.appVersion); XCTAssertNotNil(f.osVersion)
            }
            for f in feedback {
                if let email = f.email { XCTAssertTrue(email.hasSuffix("@example.com"), email) }
                if let from = IssueBodyParser.parse(f.rawBody).fromAddress {
                    XCTAssertTrue(from.hasSuffix("@example.com"), from)
                }
            }
        }
    }

    func testEachProductHasANonEnglishFeedbackForTranslation() throws {
        let context = try makeSeededContext()
        for p in try products(context) {
            let languages = openIssues(p, context).filter { !TaskItem.isTask($0) }
                .compactMap { LanguageDetector.detect($0.description) }
            XCTAssertTrue(languages.contains { !$0.hasPrefix("en") }, "\(p.repo): \(languages)")
        }
    }

    func testRoughlyHalfTheFeedbackIsAlreadySeen() throws {
        let context = try makeSeededContext()
        let seen = try context.fetch(FetchDescriptor<SeenIssue>())
        for p in try products(context) {
            let feedback = Set(openIssues(p, context).filter { !TaskItem.isTask($0) }.map(\.number))
            let seenHere = Set(seen.filter { $0.repoName == p.repo }.map(\.issueNumber))
            XCTAssertTrue(seenHere.isSubset(of: feedback), "only feedback is marked seen")
            XCTAssertGreaterThan(seenHere.count, 0)
            XCTAssertLessThan(seenHere.count, feedback.count, "some must stay unread")
        }
    }

    func testSeedingIsDeterministic() throws {
        func fingerprint(_ context: ModelContext) throws -> [String] {
            let issues = try context.fetch(FetchDescriptor<CachedIssue>())
                .map { "\($0.repoName)#\($0.number) \($0.title) \($0.rawBody.hashValue)" }
            let versions = try context.fetch(FetchDescriptor<ProjectVersion>()).map { "\($0.repoName) v\($0.name)" }
            let products = try context.fetch(FetchDescriptor<Product>()).map { "\($0.id) \($0.displayName)" }
            return (issues + versions + products).sorted()
        }
        XCTAssertEqual(try fingerprint(makeSeededContext()), try fingerprint(makeSeededContext()))
    }

    func testSeedingTwiceIntoTheSameContextIsANoOp() throws {
        let context = try makeSeededContext()
        let before = try context.fetchCount(FetchDescriptor<CachedIssue>())
        try MockDataSeeder.seed(into: context, now: Self.now)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Product>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CachedIssue>()), before)
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project and verify the tests fail.** Run the xcodegen recipe (the test file is new), then the targeted command with `MockDataSeederTests`.
  Expected: BUILD FAILED, `cannot find 'MockDataSeeder' in scope`.

- [ ] **Step 3: Implement the engine.** Create `LoveLetter/Services/Debug/MockDataSeeder.swift`:

```swift
#if DEBUG
import Foundation
import SwiftData
import LoveLetterCore

/// Seeds a fresh, in-memory container with a realistic demo dataset for the DEBUG "Mock data"
/// mode (see `DebugSettings`, `LoveLetterApp.init`): products, feedback from every source,
/// tasks and releases. Deterministic for a given `now`. Never pointed at the real stores.
@MainActor
enum MockDataSeeder {
    /// Fake GitHub owner of every mock product. No Keychain token exists for it, so any write
    /// attempted in mock mode fails through the normal "No GitHub token" error path.
    static let owner = "mock-studio"

    enum Origin {
        case sdk(type: FeedbackType, appVersion: String, build: String, device: String,
                 osName: String, osVersion: String, email: String?)
        case appStore(rating: Int, territory: String, nickname: String)
        case email(from: String)
    }

    struct FeedbackSpec {
        let number: Int
        let title: String
        let text: String
        let origin: Origin
        var extraLabels: [String] = []
        let hoursAgo: Double
    }

    struct TaskSpec {
        let number: Int
        let title: String
        let notes: String
        let status: TaskStatus
        let priority: TaskPriority
        let milestone: String?
        let refs: [Int]
        let hoursAgo: Double
    }

    struct VersionSpec {
        let name: String
        let title: String
        let changelog: String
        let released: Bool
        let daysAgo: Double
    }

    struct ProductSpec {
        let id: UUID
        let displayName: String
        let repo: String
        let colorHex: String
        let feedback: [FeedbackSpec]
        let tasks: [TaskSpec]
        let versions: [VersionSpec]
    }

    /// Inserts and saves the whole catalog. A no-op when the context already holds products, so
    /// it can never double-seed.
    static func seed(into context: ModelContext, now: Date = Date()) throws {
        guard try context.fetchCount(FetchDescriptor<Product>()) == 0 else { return }
        for (index, spec) in products.enumerated() {
            let product = Product(id: spec.id, displayName: spec.displayName, owner: owner,
                                  repo: spec.repo, colorHex: spec.colorHex,
                                  createdAt: now.addingTimeInterval(-Double(90 - index) * 86_400))
            product.sortOrder = Double(index)
            context.insert(product)

            for issue in try issues(for: spec, now: now) {
                context.insert(CachedIssue.from(issue, repoOwner: owner, repoName: spec.repo))
            }

            for (vIndex, v) in spec.versions.enumerated() {
                let created = now.addingTimeInterval(-v.daysAgo * 86_400)
                context.insert(ProjectVersion(
                    repoOwner: owner, repoName: spec.repo, name: v.name,
                    releaseTitle: v.title, changelog: v.changelog,
                    milestoneNumber: vIndex + 1,
                    releaseTag: v.released ? "v\(v.name)" : nil,
                    releasePublished: v.released,
                    releasedAt: v.released ? created.addingTimeInterval(3 * 86_400) : nil,
                    createdAt: created))
            }

            // Every even-numbered feedback is already seen; the rest keep their unread dot.
            for f in spec.feedback where f.number.isMultiple(of: 2) {
                context.insert(SeenIssue(repoOwner: owner, repoName: spec.repo,
                                         issueNumber: f.number, seenAt: now))
            }
        }
        try context.save()
    }

    /// Renders every spec through the producers real issues come from (SDK body formatter, App
    /// Store synthesizer, email-mirror builders, TaskService). Then it decodes them with the
    /// production GraphQL page decoder, so body parsing, labels, source and rating resolution
    /// all match a real fetch exactly.
    static func issues(for spec: ProductSpec, now: Date) throws -> [FeedbackIssue] {
        let iso = ISO8601DateFormatter()
        var nodes: [[String: Any]] = []
        for f in spec.feedback {
            let created = now.addingTimeInterval(-f.hoursAgo * 3600)
            let rendered = render(f, productName: spec.displayName, repo: spec.repo, createdAt: created)
            nodes.append(node(number: f.number, title: rendered.title, body: rendered.body,
                              labels: rendered.labels + f.extraLabels, milestone: nil,
                              date: iso.string(from: created)))
        }
        for t in spec.tasks {
            let created = now.addingTimeInterval(-t.hoursAgo * 3600)
            // Always OPEN: the app only reads open cached rows, so a closed "done" task would vanish.
            nodes.append(node(number: t.number, title: t.title,
                              body: TaskService.body(prose: t.notes, feedbackRefs: t.refs),
                              labels: TaskService.labels(status: t.status, priority: t.priority),
                              milestone: t.milestone, date: iso.string(from: created)))
        }
        let envelope: [String: Any] = [
            "data": ["repository": ["issues": [
                "pageInfo": ["hasNextPage": false],
                "nodes": nodes,
            ]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try IssueLoader.decodePageForTesting(data: data, owner: owner, repo: spec.repo)
    }

    private static func render(_ f: FeedbackSpec, productName: String, repo: String,
                               createdAt: Date) -> (title: String, body: String, labels: [String]) {
        switch f.origin {
        case let .sdk(type, appVersion, build, device, osName, osVersion, email):
            let report = FeedbackReport(type: type, title: f.title, description: f.text, contactEmail: email)
            let info = DeviceInfo(appName: productName, appVersion: appVersion, buildNumber: build,
                                  model: device, osName: osName, osVersion: osVersion)
            return (f.title,
                    IssueBodyFormatter.format(report: report, deviceInfo: info),
                    IssueBodyFormatter.labels(for: type))
        case let .appStore(rating, territory, nickname):
            let review = ASCReview(id: "mock-\(repo)-\(f.number)", rating: rating, title: f.title,
                                   body: f.text, reviewerNickname: nickname, createdDate: createdAt,
                                   territory: territory, response: nil)
            return (AppStoreReviewSynthesizer.title(for: review),
                    AppStoreReviewSynthesizer.body(for: review),
                    AppStoreReviewSynthesizer.labels(for: review))
        case let .email(from):
            let block = IssueBodyFormatter.sourceMetadataBlock(
                source: FeedbackSource.email.rawValue,
                fromAddress: MailToGitHubMirror.redact(from),
                messageId: "<mock-\(repo)-\(f.number)@example.com>")
            return (MailToFeedbackMirror.issueTitle(subject: f.title),
                    f.text + "\n\n" + block,
                    [FeedbackSource.email.githubLabel ?? "source:email"])
        }
    }

    private static func node(number: Int, title: String, body: String, labels: [String],
                             milestone: String?, date: String) -> [String: Any] {
        var node: [String: Any] = [
            "number": number,
            "title": title,
            "body": body,
            "createdAt": date,
            "updatedAt": date,
            "state": "OPEN",
            "labels": ["nodes": labels.map { ["name": $0, "color": color(forLabel: $0)] }],
        ]
        if let milestone { node["milestone"] = ["title": milestone] }
        return node
    }

    private static func color(forLabel name: String) -> String {
        if let managed = LoveLetterLabels.managed.first(where: { $0.name == name }) { return managed.color }
        if name.hasPrefix("rating:") { return "fbca04" }
        switch name {
        case "bug": return "d73a4a"
        case "feature-request": return "a2eeef"
        case "user-submitted": return "c5def5"
        case "question": return "d876e3"
        case "source:app-store": return "1d76db"
        case "source:email": return "bfd4f2"
        default: return "ededed"
        }
    }
}
#endif
```

- [ ] **Step 4: Implement the catalog.** Create `LoveLetter/Services/Debug/MockDataCatalog.swift`:

```swift
#if DEBUG
import Foundation
import LoveLetterCore

/// The demo content. Plain data, kept apart from the seeding engine so copy edits never touch
/// logic. Rules the tests enforce:
/// - every product mixes all three sources and has one non-English item;
/// - tasks cover every status and priority and reference existing feedback numbers;
/// - each product has a released, a WIP (a started task in its milestone) and a new version;
/// - emails are @example.com; no attachments; no App Store / inbox / connected-repo wiring.
extension MockDataSeeder {
    static let products: [ProductSpec] = [pixelJournal, tidyBudget, trailBuddy]

    // MARK: Pixel Journal (iOS journaling app)

    static let pixelJournal = ProductSpec(
        id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000001")!,
        displayName: "Pixel Journal", repo: "pixel-journal", colorHex: "7b8cff",
        feedback: [
            FeedbackSpec(number: 1, title: "Photos disappear after editing an entry",
                         text: "I added three photos to yesterday's entry, then fixed a typo in the text. After saving, only the first photo is left. Happens every time I edit an entry with more than one photo.",
                         origin: .sdk(type: .bug, appVersion: "2.3.0", build: "231", device: "iPhone17,1", osName: "iOS", osVersion: "27.0", email: "maya.chen@example.com"),
                         hoursAgo: 3),
            FeedbackSpec(number: 2, title: "Dark mode for the calendar view",
                         text: "The calendar is still bright white when the rest of the app is dark. Writing at night it's really glaring.",
                         origin: .sdk(type: .featureRequest, appVersion: "2.3.0", build: "231", device: "iPad16,3", osName: "iPadOS", osVersion: "27.0", email: nil),
                         hoursAgo: 9),
            FeedbackSpec(number: 3, title: "Finally a journal I stick with",
                         text: "The daily prompts and streaks got me writing every day for two months now. Stickers are adorable.",
                         origin: .appStore(rating: 5, territory: "USA", nickname: "sunnyday_writes"),
                         hoursAgo: 20),
            FeedbackSpec(number: 4, title: "Sync lost a week of entries",
                         text: "Switched to a new iPhone and everything from last week is gone. Please help, those entries matter to me.",
                         origin: .appStore(rating: 2, territory: "GBR", nickname: "tomk"),
                         hoursAgo: 30),
            FeedbackSpec(number: 5, title: "Export to PDF?",
                         text: "Hi! Is there a way to export a whole year as a PDF? I'd love to print a book of my entries for my mum.",
                         origin: .email(from: "r.alvarez@example.com"),
                         hoursAgo: 44),
            FeedbackSpec(number: 6, title: "App stürzt beim Öffnen alter Einträge ab",
                         text: "Seit dem letzten Update stürzt die App jedes Mal ab, wenn ich einen Eintrag vom letzten Jahr öffne. Neuere Einträge funktionieren ohne Probleme.",
                         origin: .sdk(type: .bug, appVersion: "2.3.0", build: "231", device: "iPhone16,2", osName: "iOS", osVersion: "26.4", email: "lena.m@example.com"),
                         hoursAgo: 52),
            FeedbackSpec(number: 7, title: "Can I lock individual entries with Face ID?",
                         text: "Some entries are private. Could I lock just those behind Face ID instead of the whole app?",
                         origin: .sdk(type: .featureRequest, appVersion: "2.2.1", build: "220", device: "iPhone15,4", osName: "iOS", osVersion: "26.4", email: nil),
                         extraLabels: ["question"],
                         hoursAgo: 70),
            FeedbackSpec(number: 8, title: "Lovely, wish it had widgets",
                         text: "Beautiful app. A home-screen widget with today's prompt would make it perfect.",
                         origin: .appStore(rating: 4, territory: "CAN", nickname: "maplewrites"),
                         hoursAgo: 96),
        ],
        tasks: [
            TaskSpec(number: 9, title: "Keep all photos when saving an edited entry",
                     notes: "The edit flow rebuilds the attachment list from the first photo only.",
                     status: .inProgress, priority: .high, milestone: "2.4.0", refs: [1], hoursAgo: 26),
            TaskSpec(number: 10, title: "Investigate lost entries after device migration",
                     notes: "Check whether the CloudKit zone is reset on the first launch of a restored device.",
                     status: .todo, priority: .high, milestone: "2.4.0", refs: [4], hoursAgo: 28),
            TaskSpec(number: 11, title: "Dark calendar theme",
                     notes: "Match the calendar grid to the system appearance.",
                     status: .todo, priority: .med, milestone: "2.5.0", refs: [2], hoursAgo: 60),
            TaskSpec(number: 12, title: "Export a date range as PDF",
                     notes: "Paginated PDF with photos; share sheet on iOS.",
                     status: .todo, priority: .low, milestone: nil, refs: [5], hoursAgo: 80),
            TaskSpec(number: 13, title: "Fix crash opening entries from 2025",
                     notes: "A legacy date format in old entries crashes the decoder.",
                     status: .done, priority: .high, milestone: "2.3.0", refs: [6], hoursAgo: 200),
            TaskSpec(number: 14, title: "Per-entry Face ID lock",
                     notes: "LocalAuthentication gate on entries marked private.",
                     status: .todo, priority: .med, milestone: "2.5.0", refs: [7], hoursAgo: 100),
        ],
        versions: [
            VersionSpec(name: "2.3.0", title: "Stickers & streaks",
                        changelog: "- Sticker packs for entries\n- Writing streaks\n- Fixed a crash when opening entries from 2025",
                        released: true, daysAgo: 40),
            VersionSpec(name: "2.4.0", title: "Sync you can trust",
                        changelog: "- Photos survive edits\n- Safer sync after moving to a new device",
                        released: false, daysAgo: 12),
            VersionSpec(name: "2.5.0", title: "Night owl",
                        changelog: "- Dark calendar\n- Face ID lock for private entries",
                        released: false, daysAgo: 2),
        ])

    // MARK: Tidy Budget (Mac + iPhone budgeting app)

    static let tidyBudget = ProductSpec(
        id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000002")!,
        displayName: "Tidy Budget", repo: "tidy-budget", colorHex: "34d399",
        feedback: [
            FeedbackSpec(number: 1, title: "CSV import skips rows with commas in the payee",
                         text: "Importing my bank's CSV drops every row where the payee has a comma, like \"Smith, J\". Quoted fields should be kept.",
                         origin: .sdk(type: .bug, appVersion: "1.8.0", build: "180", device: "Mac16,1", osName: "macOS", osVersion: "27.0", email: "dev.ops@example.com"),
                         hoursAgo: 2),
            FeedbackSpec(number: 2, title: "Shared budgets with my partner",
                         text: "We'd love to share one household budget and both add expenses from our own phones.",
                         origin: .sdk(type: .featureRequest, appVersion: "1.8.0", build: "180", device: "iPhone17,3", osName: "iOS", osVersion: "27.0", email: nil),
                         hoursAgo: 8),
            FeedbackSpec(number: 3, title: "Subscription charged twice",
                         text: "I was billed twice this month for the yearly plan. Please refund one of them.",
                         origin: .appStore(rating: 1, territory: "USA", nickname: "budgetbuddy88"),
                         hoursAgo: 15),
            FeedbackSpec(number: 4, title: "Best budgeting app on the Mac",
                         text: "Fast, native, and the reports are gorgeous. Worth every cent.",
                         origin: .appStore(rating: 5, territory: "AUS", nickname: "koala_cash"),
                         hoursAgo: 27),
            FeedbackSpec(number: 5, title: "Question about bank sync",
                         text: "Does Tidy Budget connect to my bank directly, or do I always need to import files?",
                         origin: .email(from: "samir@example.com"),
                         extraLabels: ["question"],
                         hoursAgo: 40),
            FeedbackSpec(number: 6, title: "Los totales mensuales no coinciden",
                         text: "El resumen de septiembre muestra un total distinto al de la lista de transacciones. Faltan unos cuarenta euros y no encuentro por qué.",
                         origin: .sdk(type: .bug, appVersion: "1.8.0", build: "180", device: "Mac15,12", osName: "macOS", osVersion: "26.4", email: "lucia.g@example.com"),
                         hoursAgo: 55),
            FeedbackSpec(number: 7, title: "Keyboard shortcut to add a transaction",
                         text: "Please add Command-N for a new transaction. I enter dozens a week and always reach for the mouse.",
                         origin: .sdk(type: .featureRequest, appVersion: "1.7.2", build: "172", device: "Mac16,10", osName: "macOS", osVersion: "26.4", email: nil),
                         hoursAgo: 75),
        ],
        tasks: [
            TaskSpec(number: 8, title: "Handle quoted commas in CSV import",
                     notes: "RFC 4180 quoting in the importer.",
                     status: .done, priority: .high, milestone: "1.8.0", refs: [1], hoursAgo: 300),
            TaskSpec(number: 9, title: "Shared budgets via CloudKit sharing",
                     notes: "CKShare for the household budget zone.",
                     status: .inProgress, priority: .med, milestone: "1.9.0", refs: [2], hoursAgo: 30),
            TaskSpec(number: 10, title: "Investigate duplicate subscription charge",
                     notes: "Check StoreKit transaction history for double renewals.",
                     status: .todo, priority: .high, milestone: nil, refs: [3], hoursAgo: 14),
            TaskSpec(number: 11, title: "Reconcile monthly totals with the transaction list",
                     notes: "The summary excludes split transactions.",
                     status: .todo, priority: .med, milestone: "2.0.0", refs: [6], hoursAgo: 50),
            TaskSpec(number: 12, title: "Command-N adds a transaction",
                     notes: "Menu command plus toolbar button.",
                     status: .inProgress, priority: .low, milestone: "1.9.0", refs: [7], hoursAgo: 60),
        ],
        versions: [
            VersionSpec(name: "1.8.0", title: "Clean imports",
                        changelog: "- CSV import keeps quoted payees\n- Faster reports",
                        released: true, daysAgo: 35),
            VersionSpec(name: "1.9.0", title: "Better together",
                        changelog: "- Shared household budgets\n- Command-N for a new transaction",
                        released: false, daysAgo: 10),
            VersionSpec(name: "2.0.0", title: "Tidy 2",
                        changelog: "- Monthly totals include split transactions",
                        released: false, daysAgo: 1),
        ])

    // MARK: Trail Buddy (iPhone + Watch hiking app)

    static let trailBuddy = ProductSpec(
        id: UUID(uuidString: "6F1C2A10-0000-4000-8000-000000000003")!,
        displayName: "Trail Buddy", repo: "trail-buddy", colorHex: "ffb347",
        feedback: [
            FeedbackSpec(number: 1, title: "GPS track drifts under tree cover",
                         text: "In dense forest my recorded track zig-zags up to 50 m off the trail, so the distance ends up way too long.",
                         origin: .sdk(type: .bug, appVersion: "3.1.0", build: "310", device: "iPhone17,1", osName: "iOS", osVersion: "27.0", email: "hiker.jo@example.com"),
                         hoursAgo: 1),
            FeedbackSpec(number: 2, title: "Great maps, battery drain is rough",
                         text: "Love the topo maps, but a five-hour hike eats seventy percent of my battery.",
                         origin: .appStore(rating: 3, territory: "DEU", nickname: "alpenwanderer"),
                         hoursAgo: 12),
            FeedbackSpec(number: 3, title: "Saved me on a foggy ridge",
                         text: "Lost the trail in thick fog and the offline map got me back to the hut. Thank you!",
                         origin: .appStore(rating: 5, territory: "NZL", nickname: "kiwi_tramper"),
                         hoursAgo: 22),
            FeedbackSpec(number: 4, title: "Offline maps for whole national parks",
                         text: "Downloading tile by tile is tedious. Let me grab an entire park before a trip.",
                         origin: .sdk(type: .featureRequest, appVersion: "3.1.0", build: "310", device: "iPad14,8", osName: "iPadOS", osVersion: "27.0", email: nil),
                         hoursAgo: 34),
            FeedbackSpec(number: 5, title: "Apple Watch complication request",
                         text: "Could you add a watch face complication showing distance and elevation gain?",
                         origin: .email(from: "p.nakamura@example.com"),
                         hoursAgo: 48),
            FeedbackSpec(number: 6, title: "L'altitude affichée est fausse",
                         text: "Sur le sentier du Mont Blanc, l'altitude affichée est décalée d'environ deux cents mètres par rapport aux panneaux.",
                         origin: .sdk(type: .bug, appVersion: "3.1.0", build: "310", device: "iPhone17,3", osName: "iOS", osVersion: "26.4", email: "camille.d@example.com"),
                         hoursAgo: 58),
            FeedbackSpec(number: 7, title: "Workout doesn't end when I stop on the watch",
                         text: "Ending the hike on my watch leaves the workout running on the phone until I open the app.",
                         origin: .sdk(type: .bug, appVersion: "3.0.4", build: "304", device: "Watch7,1", osName: "watchOS", osVersion: "26.4", email: nil),
                         hoursAgo: 66),
            FeedbackSpec(number: 8, title: "Can I share my live location with friends?",
                         text: "Would be great for solo hikes: a link my partner can open to see where I am.",
                         origin: .sdk(type: .featureRequest, appVersion: "3.1.0", build: "310", device: "iPhone16,2", osName: "iOS", osVersion: "27.0", email: nil),
                         extraLabels: ["question"],
                         hoursAgo: 90),
        ],
        tasks: [
            TaskSpec(number: 9, title: "Smooth GPS tracks under canopy",
                     notes: "Kalman filter plus horizontal-accuracy gating.",
                     status: .inProgress, priority: .high, milestone: "3.2.0", refs: [1], hoursAgo: 20),
            TaskSpec(number: 10, title: "Cut background location battery use",
                     notes: "Adaptive sampling when speed is steady.",
                     status: .inProgress, priority: .high, milestone: "3.2.0", refs: [2], hoursAgo: 24),
            TaskSpec(number: 11, title: "Offline map packs per national park",
                     notes: "Region download with progress and a storage estimate.",
                     status: .todo, priority: .med, milestone: "3.3.0", refs: [4], hoursAgo: 40),
            TaskSpec(number: 12, title: "Watch complication: distance & elevation",
                     notes: "WidgetKit accessory families.",
                     status: .todo, priority: .low, milestone: "3.3.0", refs: [5, 8], hoursAgo: 45),
            TaskSpec(number: 13, title: "Calibrate barometric altitude",
                     notes: "Use DEM elevation at the trail start as the reference.",
                     status: .done, priority: .high, milestone: "3.1.0", refs: [6], hoursAgo: 400),
            TaskSpec(number: 14, title: "End the phone workout when the watch ends it",
                     notes: "Observe the HKWorkoutSession state on the phone.",
                     status: .done, priority: .med, milestone: "3.2.0", refs: [7], hoursAgo: 35),
        ],
        versions: [
            VersionSpec(name: "3.1.0", title: "Summit",
                        changelog: "- Accurate barometric altitude\n- New topo map style",
                        released: true, daysAgo: 50),
            VersionSpec(name: "3.2.0", title: "All-day battery",
                        changelog: "- Smoother GPS tracks under trees\n- Lower battery use\n- Watch ends the phone workout",
                        released: false, daysAgo: 14),
            VersionSpec(name: "3.3.0", title: "Off the grid",
                        changelog: "- National park map packs\n- Watch complication",
                        released: false, daysAgo: 3),
        ])
}
#endif
```

- [ ] **Step 5: Regenerate the project and run the tests.** Run the xcodegen recipe (two new source files), then the targeted command with `MockDataSeederTests`.
  Expected: all 10 tests pass.
  - If `testEachProductHasANonEnglishFeedbackForTranslation` fails, `LanguageDetector.detect` returned nil or `en`. Lengthen that product's non-English `text` (more words in the same language) rather than weakening the test.
  - If the Swift type-checker times out on the catalog, split each product's `feedback:` / `tasks:` arrays into their own `private static let` constants.

- [ ] **Step 6: Commit.**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
git add LoveLetter/Services/Debug/MockDataSeeder.swift LoveLetter/Services/Debug/MockDataCatalog.swift LoveLetterTests/MockDataSeederTests.swift LoveLetter.xcodeproj/project.pbxproj
git commit -m "feat(debug): deterministic mock data seeder (products, feedback, tasks, releases)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Launch-time mock mode (container swap, side-effect guards, environment flag, badge)

**Files:**
- Create: `LoveLetter/App/MockDataMode.swift` (environment key + badge modifier; all builds)
- Modify: `LoveLetter/App/LoveLetterApp.swift`
- Modify: `LoveLetter/App/RootView.swift` (one modifier line)
- Test: `LoveLetterTests/LaunchModeTests.swift`
- Modify (via xcodegen): `LoveLetter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes:
  - `DebugSettings.isMockDataActiveAtLaunch` and `DebugSettings()` (Task 1)
  - `IssueLoaderRegistry(…, cacheOnly:)` (Task 2)
  - `MockDataSeeder.seed(into:now:)` (Task 3)
- Produces:
  - `LoveLetterApp.LaunchMode` (`.testing`, `.mock`, `.live`; `Equatable`)
  - `static func LoveLetterApp.resolveLaunchMode(isTesting: Bool) -> LaunchMode`
  - `static func LoveLetterApp.makeContainer(mode: LaunchMode) throws -> ModelContainer`
  - `EnvironmentValues.isMockDataMode: Bool` (default `false`)
  - `struct MockDataBadgeOverlay: ViewModifier`
  - `DebugSettings` injected into `sharedEnvironment` (DEBUG), which Task 5 reads with `@Environment(DebugSettings.self)`

- [ ] **Step 1: Write the failing tests.** Create `LoveLetterTests/LaunchModeTests.swift`:

```swift
#if DEBUG
import XCTest
import SwiftData
@testable import LoveLetter

@MainActor
final class LaunchModeTests: XCTestCase {
    func testTestHostAlwaysWinsOverMockMode() {
        // Even if the developer left mock data on, the test host keeps its own in-memory stack.
        XCTAssertEqual(LoveLetterApp.resolveLaunchMode(isTesting: true), .testing)
    }

    func testMockContainerIsInMemoryAndSeedsIntoTheStores() throws {
        let container = try LoveLetterApp.makeContainer(mode: .mock)
        XCTAssertTrue(container.configurations.allSatisfy(\.isStoredInMemoryOnly),
                      "mock mode must never open the on-disk / CloudKit stores")
        try MockDataSeeder.seed(into: ModelContext(container), now: Date())
        let products = ProductStore(context: ModelContext(container))
        XCTAssertEqual(products.repos.map(\.owner), ["mock-studio", "mock-studio", "mock-studio"])
        let versions = VersionStore(context: ModelContext(container))
        XCTAssertEqual(versions.versions(owner: "mock-studio", repo: "pixel-journal").count, 3)
    }
}
#endif
```

- [ ] **Step 2: Regenerate the project and verify the tests fail.** Run the xcodegen recipe, then the targeted command with `LaunchModeTests`.
  Expected: BUILD FAILED, `type 'LoveLetterApp' has no member 'resolveLaunchMode'`.

- [ ] **Step 3: Add the environment flag and badge.** Create `LoveLetter/App/MockDataMode.swift`:

```swift
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

/// Shows a small "MOCK DATA" capsule while `\.isMockDataMode` is on, so demo data is never
/// mistaken for real data. It's a modifier rather than an inline overlay to keep RootView's long
/// modifier chain within the type-checker's budget. Inert in Release.
struct MockDataBadgeOverlay: ViewModifier {
    @Environment(\.isMockDataMode) private var isMockDataMode

    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .bottomLeading) {
            if isMockDataMode {
                Text("MOCK DATA")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
                    .padding(12)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Mock data mode")
            }
        }
        #else
        content
        #endif
    }
}
```

- [ ] **Step 4: Add the launch-mode helpers to `LoveLetterApp.swift`.** Append this extension to the end of the file:

```swift
// MARK: - Launch mode & container

extension LoveLetterApp {
    /// Which data stack this process runs on. `.mock` is only ever produced in DEBUG builds.
    enum LaunchMode: Equatable { case testing, mock, live }

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
```

Both branches are the current `init()` container code moved verbatim; only `container =` became `return`. Before deleting the originals in Step 5, diff the moved lines against them. The model-type lists, config names, and the `"iCloud.com.amirhayek.AppFeedback"` identifier must match exactly, and the variadic `for: A.self, B.self, …` form must stay. If `main` gained a model type since this plan was written, include it in both lists.

- [ ] **Step 5: Rewire `init()`.** Make these edits in `LoveLetterApp.swift`:

(a) Add stored properties below `private let repoConfigSnapshot = ProductConfigSnapshot()`:

```swift
    /// True when this process launched in DEBUG mock-data mode (see `DebugSettings`).
    private let isMockDataMode: Bool
    #if DEBUG
    @State private var debugSettings = DebugSettings()
    #endif
```

(b) Replace everything from `let isTesting = …` through the end of the container `do { … } catch { … }` block, which ends with `fatalError("Failed to create ModelContainer: \(error)")\n        }`, with:

```swift
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let launchMode = Self.resolveLaunchMode(isTesting: isTesting)
        let isMock = launchMode == .mock
        isMockDataMode = isMock
        do {
            container = try Self.makeContainer(mode: launchMode)
        } catch {
            assertionFailure("Failed to create ModelContainer: \(error)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        #if DEBUG
        // Seed BEFORE any store is constructed, so their first reload() sees the mock rows.
        if isMock { Self.seedMockData(into: container) }
        #endif
```

(c) Migrations: change `if !isTesting {` (the block running `MailAccountMigration` / `ProductMigration`) to `if launchMode == .live {`.

(d) On-disk logs: change both `isTesting ? nil : {` occurrences (`activityLogURL` and `failureStoreURL`) to `launchMode != .live ? nil : {`. Mock activity must never land in `~/Library/Application Support/AppFeedback/*.json`.

(e) Issue registry: replace

```swift
        let issueRegistry = IssueLoaderRegistry(
            factory: { cfg in IssueLoader(config: cfg, activityLog: activityLogValue, cacheContext: cacheCtx) },
            notificationService: service
        )
        issueRegistry.triageSink = { groups in
            await triageCoordinatorLocal.processLoaded(groups)
        }
```

with

```swift
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
```

(f) macOS CLI: change `responder.start()` to `if !isMock { responder.start() }`. Change `if !isTesting { CLIInstaller.refreshInstalledLinks() }` to `if launchMode == .live { CLIInstaller.refreshInstalledLinks() }`. Keep the existing comments.

(g) `sharedEnvironment`: replace `.environment(\.notificationService, notificationService)` with the lines below, and add the flag and settings right after `.environment(feedbackAttachmentDownloaderHolder)`:

```swift
            // nil in mock mode: RootView's backlog snapshot would otherwise write mock repo keys
            // into the real UserDefaults / NotifiedIssueStore (this also hides the Notifications pane).
            .environment(\.notificationService, isMockDataMode ? nil : notificationService)
```

```swift
            .environment(\.isMockDataMode, isMockDataMode)
            #if DEBUG
            .environment(debugSettings)
            #endif
```

(h) `body`: change `.task { await notificationService.requestAuthorizationIfNeeded() }` to

```swift
                .task { if !isMockDataMode { await notificationService.requestAuthorizationIfNeeded() } }
```

and replace the `.onAppear { … }` block with

```swift
                .onAppear {
                    // Mock mode has no mail accounts or ASC credentials; don't even start the pollers.
                    if !isMockDataMode {
                        #if canImport(SwiftMail)
                        coordinatorRegistry?.start()
                        #endif
                        appStoreRegistry.start()
                    }
                    issueLoaderRegistry.start()
                }
```

After these edits `isTesting` is only used by `resolveLaunchMode`. That's expected; don't remove it.

- [ ] **Step 6: Add the badge to `RootView`.** In `LoveLetter/App/RootView.swift`, insert `.modifier(MockDataBadgeOverlay())` on its own line directly above `        .sheet(isPresented: $showSettings) {`, which is the first modifier after the `NavigationSplitView`'s closing brace.

- [ ] **Step 7: Regenerate the project, run the tests, and build.** Run the xcodegen recipe (`MockDataMode.swift` is new). Then run the targeted command with `-only-testing:LoveLetterTests_macOS/LaunchModeTests -only-testing:LoveLetterTests_macOS/IssueLoaderRegistryTests`. Expected: pass.
  Then run the macOS build and the iOS build commands. Expected: `** BUILD SUCCEEDED **` for both.

- [ ] **Step 8: Commit.**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
git add LoveLetter/App/MockDataMode.swift LoveLetter/App/LoveLetterApp.swift LoveLetter/App/RootView.swift LoveLetterTests/LaunchModeTests.swift LoveLetter.xcodeproj/project.pbxproj
git commit -m "feat(debug): launch into seeded in-memory mock data with side effects off

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Debug settings pane (macOS sidebar + iOS link)

**Files:**
- Create: `LoveLetter/Views/Settings/DebugSettingsView.swift`
- Modify: `LoveLetter/Views/Settings/SettingsView.swift`
- Test: `LoveLetterTests/SettingsNavigationTests.swift` (extend)
- Modify (via xcodegen): `LoveLetter.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `DebugSettings` (`useMockData`, `needsRelaunch`) from the environment (Task 4 injects it); `SettingsIconRow` (macOS).
- Produces: `SettingsSelection.debug` (all builds) and `struct DebugSettingsView: View` (`#if DEBUG`).

- [ ] **Step 1: Write the failing test.** In `LoveLetterTests/SettingsNavigationTests.swift`, change the array in `normalizedKeepsNonProductSelections` to:

```swift
        for sel in [SettingsSelection.email, .intelligence, .notifications, .cli, .debug] {
```

- [ ] **Step 2: Verify the test fails.** Targeted command with `SettingsNavigationTests`. Expected: BUILD FAILED, `type 'SettingsSelection' has no member 'debug'`.

- [ ] **Step 3: Create the view.** Create `LoveLetter/Views/Settings/DebugSettingsView.swift`:

```swift
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
```

- [ ] **Step 4: Wire it into `SettingsView.swift`.**

(a) Add the case to the enum, after `case cli`:

```swift
    /// DEBUG-only pane; the row and detail are fenced, the case itself is harmless in Release.
    case debug
```

(b) macOS sidebar: add a new section right after the closing `}` of the `Section { SettingsIconRow(title: "Email", …) … SettingsIconRow(title: "CLI & AI Skill", …) }` block, still inside `List(selection:)`:

```swift
                #if DEBUG
                Section {
                    SettingsIconRow(title: "Debug", systemImage: "ladybug.fill", tileColor: .orange)
                        .tag(SettingsSelection.debug)
                }
                #endif
```

(c) macOS `detailContent`: add a case after `case .cli:` / `CLISettingsView()`:

```swift
        case .debug:
            #if DEBUG
            DebugSettingsView()
            #else
            EmptyView()
            #endif
```

(d) iOS `iosBody`: add a section right after the `if let notificationService { Section { … } }` block, as the last item in the `Form`:

```swift
                #if DEBUG
                Section {
                    NavigationLink {
                        DebugSettingsView()
                            .navigationTitle("Debug")
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }
                }
                #endif
```

- [ ] **Step 5: Regenerate the project, run the tests, and build.** Run the xcodegen recipe (new file). Run the targeted command with `SettingsNavigationTests`. Expected: pass. Then run the macOS and iOS build commands. Expected: both `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
git add LoveLetter/Views/Settings/DebugSettingsView.swift LoveLetter/Views/Settings/SettingsView.swift LoveLetterTests/SettingsNavigationTests.swift LoveLetter.xcodeproj/project.pbxproj
git commit -m "feat(settings): DEBUG-only Debug pane with the mock data toggle

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Final verification

**Files:** none are modified. If a check fails, fix it in the owning task's files and commit with a `fix(debug): …` message.

- [ ] **Step 1: Clean macOS Debug build.** Run the macOS build command. Expected: `** BUILD SUCCEEDED **`. If the `.cstemp` CodeSign flake appears, apply the fix from Global Constraints.

- [ ] **Step 2: iOS Simulator build.** Run the iOS build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Release build contains no mock code (success criterion 1).**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
xcodebuild build -project LoveLetter.xcodeproj -scheme LoveLetter_macOS -configuration Release -destination 'platform=macOS' -derivedDataPath "$TMPDIR/ll-release-dd" CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|\*\* BUILD" | tail -10
strings "$TMPDIR/ll-release-dd/Build/Products/Release/LoveLetter.app/Contents/MacOS/LoveLetter" | grep -cE "mock-studio|debug\.useMockData|MOCK DATA|Pixel Journal"
```

Expected: `** BUILD SUCCEEDED **`, then `0`.

- [ ] **Step 4: Full macOS test suite.**

```bash
cd /Users/amir/Developer/LoveLetter-mock-data
xcodebuild test -project LoveLetter.xcodeproj -scheme LoveLetter_macOS -destination 'platform=macOS' 2>&1 | tee "$TMPDIR/ll-tests.log" | grep -E "Test Case .* failed|✘|\*\* TEST" | head -60
```

Expected: the only failures are the known pre-existing ones in `KeychainServicePerAccountTests` and `GitHubAccountStoreTests` (about 11). All of `DebugSettingsTests`, `MockDataSeederTests`, `LaunchModeTests`, `IssueLoaderRegistryTests`, `IssueLoaderTests`, and `SettingsNavigationTests` must pass. If the run ends in a SwiftData "No eligible connection" test-host crash, rerun once. It's a known intermittent crash; compare runs before attributing it to this branch.

- [ ] **Step 5: Branch hygiene.** `git status --short` must be clean, with no stray `.xcscheme` changes. `git log --oneline main..HEAD` should list the spec commit plus Tasks 1–5.

- [ ] **Step 6: Manual run check.** Report this as a to-do for the human; an agent can't verify it headlessly.
  1. Run the DEBUG macOS app from Xcode (scheme `LoveLetter_macOS`).
  2. Open Settings ▸ **Debug** (orange ladybug row at the bottom of the sidebar) and turn **Mock data** on. Check that "Relaunch to apply" appears, then click **Relaunch Now**.
  3. Check that:
     - the sidebar shows Pixel Journal, Tidy Budget, and Trail Buddy;
     - the feedback list shows SDK / App Store (stars) / Email badges, unread dots on odd-numbered items, and a German/Spanish/French item that offers translation;
     - the Tasks & Versions inspector shows To Do / In Progress / Done tasks and New / WIP / Released versions;
     - the orange **MOCK DATA** capsule is at the bottom-left of the main window;
     - the Notifications pane is hidden.
  4. Try one write, such as changing a task's status. It should fail with the normal "No GitHub token for this repo" alert and must not crash.
  5. Turn **Mock data** off, relaunch, and confirm the real products and feedback are back, untouched, with no mock products synced to iCloud.
