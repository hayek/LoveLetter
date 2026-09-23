# Debug Settings + Mock Data Mode — Design

Date: 2026-09-23
Status: Approved (in-chat design), pending implementation

## Goal

A **Debug** settings pane that exists only in DEBUG builds. Its first control is a
**Mock data** toggle: when on, the app shows a realistic set of fake products, feedback,
tasks and releases instead of the user's real data. Uses: demos, App Store screenshots,
UI work without live GitHub/iCloud accounts.

Success criteria:

1. Release builds contain none of this code (everything is `#if DEBUG`).
2. With the toggle on (after relaunch), every main screen — sidebar products, feedback
   list/cards, task inspector, releases/versions — is populated with mock data.
3. Real data is never read, written, or synced while in mock mode, and mock data can never
   reach iCloud/CloudKit, GitHub, IMAP, App Store Connect, or the user's real stores.
4. Turning the toggle off and relaunching returns to the untouched real data.

## Non-goals (YAGNI)

- Live switching without relaunch (the ~30 stores/coordinators in `LoveLetterApp.init`
  are wired to one `ModelContainer`; rebuilding that graph at runtime is a large refactor).
- Mock mail threads / mail accounts / GitHub accounts. Email-sourced *feedback* is mocked
  as feedback issues with the email source; the Mail UI itself stays empty.
- Mock write-back. Writes that hit GitHub (create task, change status, publish release)
  may fail in mock mode; they must fail gracefully (existing error paths), not crash.
- More debug toggles. The pane is structured so more can be added later.

## Architecture

### 1. `DebugSettings` (new, `#if DEBUG`)

`LoveLetter/Services/Debug/DebugSettings.swift`

- `@Observable @MainActor final class DebugSettings` with `var useMockData: Bool`,
  persisted in `UserDefaults` under key `debug.useMockData` (injectable `UserDefaults`
  for tests).
- `static var isMockDataActiveAtLaunch: Bool` — read once at process start; this is what
  `LoveLetterApp.init` uses. The observable `useMockData` is the *pending* value; the UI
  compares the two to show "Relaunch to apply".
- Never true in the XCTest host: `LoveLetterApp.init` checks `isTesting` first, so the
  test path is unchanged.

### 2. Launch-time container swap (`LoveLetterApp.init`)

Order of precedence: `isTesting` → mock mode → real (unchanged).

In mock mode:

- Build a single **in-memory** `ModelConfiguration(isStoredInMemoryOnly: true,
  cloudKitDatabase: .none)` container with the same model list as the test path.
  The real CloudKit/local stores are never opened.
- Skip `MailAccountMigration` and `ProductMigration`.
- Run `MockDataSeeder.seed(into: ModelContext(container))` **before** the stores are
  constructed so `ProductStore.repos` etc. see the mock rows on first read.
- Activity log / outbound-failure persistence URLs → `nil` (in-memory only), so mock
  activity never lands in the real `~/Library/Application Support/AppFeedback/*.json`.
- Side effects disabled:
  - Mail sync coordinator registry: not started (no mail accounts exist anyway).
  - App Store review registry: not started (mock products have no ASC credentials).
  - `IssueLoaderRegistry`: constructed in cache-only mode (see §4), with
    `notificationService: nil` and no `triageSink` (no notifications or AI triage for
    fake issues).
  - macOS CLI responder: not started; `CLIInstaller.refreshInstalledLinks()` skipped.
  - Notification authorization request: skipped.
- A `mockDataActive` flag is injected into the environment (`EnvironmentValues`
  entry `\.isMockDataMode`, default `false`, available in all builds so views need no
  `#if`; only DEBUG code ever sets it to `true`).

Keep the diff in `LoveLetterApp.init` small: factor container creation into a helper
(e.g. `makeContainer(mode:)`) and guard the side-effect sites with a single
`let isMock` local.

### 3. `MockDataSeeder` (new, `#if DEBUG`)

`LoveLetter/Services/Debug/MockDataSeeder.swift`

Pure function of a `ModelContext` (and a fixed reference `Date` for determinism in
tests). Inserts and saves:

- **3 products** (e.g. "Pixel Journal", "Tidy Budget", "Trail Buddy") with distinct
  owner/repo slugs under a fake owner (e.g. `mock-studio`), colors, sort order.
- **Feedback** — per product 6–10 `CachedIssue` rows in state open, built via the same
  path real fetches use (`FeedbackIssue` → `CachedIssue.from(_:repoOwner:repoName:)`)
  so parsing/labels/attachments match production. Mix of:
  - sources: SDK/GitHub, email, App Store (App Store rows with ratings 1–5);
  - app versions, device models (use real identifiers from `AppleDevices.json`), OS
    versions, reporter emails (`@example.com` only), languages (include one non-English
    item so translation UI shows);
  - labels (bug / feature / question), a couple of already-translated/closed ones is not
    needed — keep it open-only.
- **Tasks** — per product 3–6 issues carrying the task label (`appfeedback:task`, i.e.
  whatever constant `TaskItem`/`TaskService` use), spread across every `TaskStatus` and
  `TaskPriority`, with task bodies containing feedback refs (the format
  `FeedbackTaskRefParser` parses) that point at real mock feedback numbers, and
  `milestoneTitle` matching a mock release name.
- **Releases** — per product `ProjectVersion` rows covering all three derived states:
  one released (`releasePublished = true`, `releasedAt`, `releaseTag`, changelog), one
  WIP (has a started task in its milestone), one new (no started tasks).
- **Seen state** — mark roughly half the feedback as seen via `SeenIssue` so unread dots
  show on the rest.
- `RepoFetchState` rows are not needed.

Issue numbers are unique per product and stable across runs.

### 4. Cache-only issue loading

`IssueLoaderRegistry` gets a `cacheOnly: Bool = false` init parameter. When true,
`load(_:fullReconcile:)` skips the token lookup and calls a new
`IssueLoader.loadCachedOnly()` which sets `state = .loaded(loadOpenIssuesFromCache(), Date())`
(an empty list is still `.loaded`, not `.idle`). The 15-minute poll loop may run; it just
re-reads the cache. No network, no Keychain access.

### 5. Token-gated UI

Some views may gate on a GitHub token existing for the product (e.g. an "add token"
empty state, or disabled task buttons). Mock products have no Keychain token. The
implementer must find such gates and, where they would block *viewing* mock data, bypass
them when `\.isMockDataMode` is true. Write actions may stay disabled or fail normally.

### 6. Debug settings UI (new, `#if DEBUG`)

`LoveLetter/Views/Settings/DebugSettingsView.swift`

- macOS: new `SettingsSelection.debug` case (the enum case itself may exist in all
  builds; the sidebar row + detail are `#if DEBUG`). Sidebar row "Debug", SF Symbol
  `ladybug.fill`, orange tile, in its own section at the bottom.
- iOS: a `Section` with a `NavigationLink` "Debug" at the bottom of the Form.
- Content (`Form`, grouped style):
  - Section "Data": Toggle "Mock data" bound to `DebugSettings.useMockData`, footer
    explaining it shows fake products, feedback, tasks and releases, never touches real
    data, and applies on relaunch.
  - When pending ≠ active: an inline notice "Relaunch to apply" plus, on macOS, a
    "Relaunch Now" button (launch a new instance of `Bundle.main.bundleURL` via
    `NSWorkspace.openApplication` with `createsNewApplicationInstance = true`, then
    `NSApp.terminate(nil)`); on iOS the text says to quit and reopen.
- `DebugSettings` is injected in `sharedEnvironment` under `#if DEBUG`.

### 7. Mock-mode indicator

When `\.isMockDataMode` is true, the main window shows a small, unobtrusive capsule badge
"MOCK DATA" (orange, caption bold) — e.g. a toolbar item or top-trailing overlay in
`RootView` — so screenshots can be taken without it only if deliberately hidden. Keep it
visible by default; screenshots are secondary to not confusing mock with real data.

## Error handling

- Seeder failure (insert/save throws) → `assertionFailure` + log; app still launches with
  whatever was saved (DEBUG only, so loud is fine).
- Writes against mock products surface through existing error UI.

## Testing

Unit tests (`LoveLetterTests`, test target `LoveLetterTests_macOS`), `#if DEBUG`:

- `MockDataSeederTests`: seed an in-memory container, assert product count (3), each
  product has feedback + tasks + ≥3 versions; every `TaskStatus` appears; every task's
  feedback refs resolve to existing mock feedback numbers in the same product; each
  version derived state (new / wip / released) appears; App Store feedback has ratings;
  seeding is deterministic (two seeds → identical titles/numbers).
- `DebugSettingsTests`: persistence round-trip through an injected `UserDefaults` suite.
- `IssueLoaderRegistry` cache-only test: with `cacheOnly: true` and a token provider that
  fails the test if called, `loadAll()` yields `.loaded` with the cached issues.

Manual check: DEBUG build on macOS, toggle on, relaunch, verify sidebar/feedback/tasks/
releases show mock data and badge; toggle off, relaunch, real data back.

## Files

New: `Services/Debug/DebugSettings.swift`, `Services/Debug/MockDataSeeder.swift`,
`Views/Settings/DebugSettingsView.swift`, tests above.
Modified: `App/LoveLetterApp.swift`, `App/RootView.swift` (badge),
`Views/Settings/SettingsView.swift`, `Services/IssueLoader.swift`,
`Services/IssueLoaderRegistry.swift`, possibly token-gated views,
`LoveLetter.xcodeproj/project.pbxproj` (via xcodegen).
