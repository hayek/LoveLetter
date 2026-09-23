import XCTest
import SwiftData
import os
@testable import LoveLetter

#if os(macOS)
/// The app-side handlers behind the parity commands, driven through the real handler code over
/// in-memory stores. GitHub is `MockURLProtocol`, App Store Connect and the mailer are fakes,
/// and secrets go to a recorder — the test host has no Keychain.
@MainActor
final class CLIAppHandlerTests: XCTestCase {

    private var context: ModelContext!
    private var products: ProductStore!
    private var versions: VersionStore!
    private var mailAccounts: MailAccountStore!
    private var gitHubAccounts: GitHubAccountStore!
    private var templates: ReplyTemplateStore!
    private var secrets: SecretRecorder!
    private var requests: RequestLog!
    private var writer: FakeIssueWriting!

    override func setUpWithError() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: Product.self, Repo.self, SeenIssue.self, MailAccount.self, GitHubAccount.self,
                MailSettings.self, MailThread.self, MailMessage.self, MailAttachment.self,
                IssueTranslation.self, IssueSummaryCache.self, ProjectVersion.self,
                SentReleaseNotification.self, CachedIssue.self, MailAttachmentLocal.self,
                MailAccountLocalState.self, RepoFetchState.self, FeedbackAttachmentLocal.self,
                ReplyTemplate.self, RepoFilterPreference.self, AppStoreReviewMirror.self,
                TriageVerdictRecord.self,
            configurations: modelConfig)
        context = ModelContext(container)
        products = ProductStore(context: context)
        versions = VersionStore(context: context)
        mailAccounts = MailAccountStore(context: context)
        gitHubAccounts = GitHubAccountStore(context: context)
        templates = ReplyTemplateStore(context: context)
        secrets = SecretRecorder()
        requests = RequestLog()
        writer = FakeIssueWriting()
        MockURLProtocol.requestHandler = nil
        // Belt and braces: nothing here may touch the real (iCloud-synced) Keychain.
        KeychainService.accessSuppressed = true
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        KeychainService.accessSuppressed = false
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeApp(fetchRepo: ((String, String, String) async throws -> GitHubRepo)? = nil,
                         ascClient: FakeAppStoreConnectClient? = nil,
                         testInbox: ((EmailSourceFormModel) async throws -> Void)? = nil,
                         mailer: FakeReleaseMailer? = nil,
                         triage: FeedbackTriageCoordinator? = nil) -> CLIRequestHandlers.AppDependencies {
        var app = CLIRequestHandlers.AppDependencies(
            products: products, versions: versions, gitHubAccounts: gitHubAccounts,
            mailAccounts: mailAccounts, seen: SeenIssueStore(context: context),
            filterStore: FilterPreferenceStore(context: context), cacheContext: context,
            triage: triage)
        app.secrets = secrets.secrets
        app.milestoneClient = GitHubMilestoneReleaseClient(session: .mock)
        app.accountToken = { "token-\($0.login)" }
        app.fetchRepo = fetchRepo ?? { owner, repo, _ in Self.repo(owner, repo) }
        if let ascClient { app.ascClient = { _, _, _ in ascClient } }
        if let testInbox { app.testInbox = testInbox }
        if let mailer { app.releaseMailer = { mailer } }
        return app
    }

    private func makeDeps(_ app: CLIRequestHandlers.AppDependencies? = nil,
                          token: String? = "gh-token") -> CLIRequestHandlers.Dependencies {
        let labels = GitHubMilestoneReleaseClient(session: .mock)
        return CLIRequestHandlers.Dependencies(
            registry: IssueLoaderRegistry(factory: { IssueLoader(config: $0, session: .mock) },
                                          tokenProvider: { _ in nil }),
            local: context, cloud: context,
            taskService: TaskService(writer: GitHubIssueWriter(session: .mock), labelClient: labels,
                                     tokenLoader: { _ in token }),
            writer: writer, tokenProvider: { _ in token },
            reply: .init(accountStore: mailAccounts, settingsStore: MailSettingsStore(context: context),
                         threadStore: MailThreadStore(context: context), tracker: OutboundSendTracker(),
                         failureStore: OutboundFailureStore(persistenceURL: nil), activityLog: ActivityLog(persistenceURL: nil),
                         templateStore: templates),
            app: app ?? makeApp())
    }

    /// A connected GitHub account row; its token comes from `accountToken`, never the Keychain.
    private func connect(_ login: String) {
        context.insert(GitHubAccount(login: login, avatarURL: nil))
        try? context.save()
        gitHubAccounts.reload()
    }

    private static func repo(_ owner: String, _ name: String, isPrivate: Bool = false) -> GitHubRepo {
        GitHubRepo(id: 1, name: name, fullName: "\(owner)/\(name)", isPrivate: isPrivate,
                   owner: .init(login: owner))
    }

    @discardableResult
    private func addProduct(_ name: String = "P", owner: String = "o", repo: String = "r") -> ProductConfig {
        let config = ProductConfig(displayName: name, owner: owner, repo: repo)
        products.add(config)
        return config
    }

    private func cache(_ number: Int, title: String = "Cached", email: String? = nil,
                       labels: [String] = [], body: String = "", milestone: String? = nil,
                       state: IssueState = .open) {
        let row = CachedIssue(repoOwner: "o", repoName: "r", number: number, title: title, createdAt: Date(),
                              state: state, rawBody: body, appName: nil, appVersion: nil, device: nil,
                              osVersion: nil, email: email, issueDescription: "",
                              labels: labels.map { IssueLabel(name: $0, colorHex: "000000") })
        row.milestoneTitle = milestone
        context.insert(row)
        try? context.save()
    }

    private func request(_ kind: CLIRequestKind, _ payload: [String: String]) -> CLIRequest {
        CLIRequest(kind: kind, payload: payload)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: CLIResponse) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(try XCTUnwrap(response.json).utf8))
    }

    private func expectError(_ code: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async -> CLIError? {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
            return nil
        } catch let error as CLIError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            return error
        } catch {
            XCTFail("expected a CLIError, got \(error)", file: file, line: line)
            return nil
        }
    }

    /// Answers every GitHub call with `status` and `json`, and records what was asked.
    private func stubGitHub(status: Int = 200, json: String = "{}") {
        let log = requests!
        MockURLProtocol.requestHandler = { request in
            log.append(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
    }

    // MARK: - products add

    func testAddSavesTheProductAsGitHubNamesItAndStoresTheToken() async throws {
        let deps = makeDeps(makeApp(fetchRepo: { _, _, token in
            XCTAssertEqual(token, "piped")
            return Self.repo("Hayek", "App-Feedback", isPrivate: true)
        }))
        let response = try await CLIRequestHandlers.addProduct(
            request(.addProduct, ["repo": "hayek/app-feedback", "token": "piped", "color": "ff6b8a"]), deps: deps)

        let saved = try XCTUnwrap(products.products.first)
        XCTAssertEqual(saved.owner, "Hayek", "canonical casing from GitHub")
        XCTAssertEqual(saved.repo, "App-Feedback")
        XCTAssertEqual(saved.displayName, "App-Feedback", "no --name ⇒ the repo name, as the wizard suggests")
        XCTAssertEqual(saved.colorHex, "ff6b8a")
        XCTAssertFalse(saved.redactEmailAddresses, "a private repo needn't redact, as in the wizard")
        let tokens = await secrets.tokens
        XCTAssertEqual(tokens.map(\.token), ["piped"])
        XCTAssertEqual(tokens.first?.productID, saved.id)
        XCTAssertEqual(try decode(ProductSummary.self, response).repo, "Hayek/App-Feedback")
    }

    // MARK: - add --create-repo

    private func repositories(existing: Set<String> = [], log: CreatedRepos) -> ProductSetup.RepositoryService {
        ProductSetup.RepositoryService(
            exists: { owner, name, _ in existing.contains("\(owner)/\(name)") },
            create: { new, _, token in await log.record("\(new.owner)/\(new.name) org:\(new.ownerIsOrganization) private:\(new.isPrivate) via:\(token)") },
            ensureLabel: { label, _, _, _, _ in await log.record("label:\(label)") })
    }

    func testCreateRepoCreatesItUnderTheOwningAccountThenAddsTheProduct() async throws {
        connect("alice"); connect("hayek")
        let log = CreatedRepos()
        var app = makeApp()
        app.repositories = repositories(log: log)
        _ = try await CLIRequestHandlers.addProduct(
            request(.addProduct, ["repo": "hayek/halo-feedback", "create": "private"]), deps: makeDeps(app))
        let entries = await log.entries
        XCTAssertEqual(entries.first, "hayek/halo-feedback org:false private:true via:token-hayek")
        XCTAssertEqual(entries.dropFirst(), ["label:bug", "label:feature-request", "label:user-submitted"])
        XCTAssertEqual(products.products.first?.repo, "halo-feedback")
        let tokens = await secrets.tokens
        XCTAssertEqual(tokens.map(\.token), ["token-hayek"])
    }

    func testCreateRepoForAnOrganizationWithAPipedToken() async throws {
        let log = CreatedRepos()
        var app = makeApp()
        app.repositories = repositories(log: log)
        app.tokenLogin = { _ in "hayek" }
        _ = try await CLIRequestHandlers.addProduct(
            request(.addProduct, ["repo": "acme/fb", "create": "public", "token": "piped"]), deps: makeDeps(app))
        let entries = await log.entries
        XCTAssertEqual(entries.first, "acme/fb org:true private:false via:piped")
    }

    func testCreateRepoRefusesATakenNameAndSavesNothing() async {
        connect("hayek")
        let log = CreatedRepos()
        var app = makeApp()
        app.repositories = repositories(existing: ["hayek/taken"], log: log)
        let error = await expectError("repo_exists") {
            _ = try await CLIRequestHandlers.addProduct(
                self.request(.addProduct, ["repo": "hayek/taken", "create": "private"]), deps: self.makeDeps(app))
        }
        XCTAssertEqual(error?.exitCode, .usage)
        let entries = await log.entries
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(products.products.isEmpty)
    }

    func testAddRedactsUnlessTheRepoIsKnownPrivate() async throws {
        _ = try await CLIRequestHandlers.addProduct(request(.addProduct, ["repo": "o/r", "token": "t"]),
                                                    deps: makeDeps())
        XCTAssertEqual(products.products.first?.redactEmailAddresses, true)
    }

    func testAddRejectsARepoThatIsAlreadyAProduct() async {
        addProduct(owner: "o", repo: "r")
        let error = await expectError("product_exists") {
            _ = try await CLIRequestHandlers.addProduct(self.request(.addProduct, ["repo": "O/R", "token": "t"]),
                                                        deps: self.makeDeps())
        }
        XCTAssertEqual(error?.exitCode, .usage)
        XCTAssertEqual(products.products.count, 1)
    }

    func testAddWithATokenThatCannotSeeTheRepoSavesNothing() async {
        let deps = makeDeps(makeApp(fetchRepo: { _, _, _ in throw GitHubAuthService.AuthError.apiError(404) }))
        let error = await expectError("auth") {
            _ = try await CLIRequestHandlers.addProduct(self.request(.addProduct, ["repo": "o/r", "token": "t"]),
                                                        deps: deps)
        }
        XCTAssertEqual(error?.exitCode, .auth)
        XCTAssertTrue(products.products.isEmpty)
        let tokens = await secrets.tokens
        XCTAssertTrue(tokens.isEmpty, "a token that failed the check must not be stored")
    }

    func testAddWithoutATokenOrAnyAccountIsAUsageError() async {
        let error = await expectError("missing_flag") {
            _ = try await CLIRequestHandlers.addProduct(self.request(.addProduct, ["repo": "o/r"]),
                                                        deps: self.makeDeps())
        }
        XCTAssertTrue(error?.hint?.contains("--token-stdin") == true)
    }

    /// With no token flag, the first connected account that can see the repo is used — the
    /// wizard's "pick the repo from an account".
    func testAddPicksTheConnectedAccountThatCanSeeTheRepo() async throws {
        connect("alice"); connect("bob")
        let deps = makeDeps(makeApp(fetchRepo: { owner, repo, token in
            guard token == "token-bob" else { throw GitHubAuthService.AuthError.apiError(404) }
            return Self.repo(owner, repo)
        }))
        _ = try await CLIRequestHandlers.addProduct(request(.addProduct, ["repo": "o/r"]), deps: deps)
        let tokens = await secrets.tokens
        XCTAssertEqual(tokens.map(\.token), ["token-bob"])
    }

    func testAddWithAnUnknownAccountListsTheConnectedOnes() async {
        connect("alice")
        let error = await expectError("account_not_found") {
            _ = try await CLIRequestHandlers.addProduct(
                self.request(.addProduct, ["repo": "o/r", "account": "mallory"]), deps: self.makeDeps())
        }
        XCTAssertEqual(error?.candidates, ["alice"])
    }

    // MARK: - products update / remove

    func testUpdateChangesOnlyWhatWasPassed() async throws {
        var original = addProduct()
        original.appStoreIssuerID = "issuer"
        original.appStoreKeyID = "key"
        original.appStoreAppAppleID = "123"
        original.colorHex = "4ef8d0"
        products.update(original)

        _ = try await CLIRequestHandlers.updateProduct(
            request(.updateProduct, ["product": "P", "name": "Renamed", "mirror": "off", "color": "none"]),
            deps: makeDeps())
        let updated = try XCTUnwrap(products.products.first)
        XCTAssertEqual(updated.displayName, "Renamed")
        XCTAssertFalse(updated.mirrorEmailsToGitHub)
        XCTAssertTrue(updated.redactEmailAddresses, "untouched")
        XCTAssertNil(updated.colorHex, "none resets to the default color")
        XCTAssertEqual(updated.appStoreAppAppleID, "123", "the App Store source must survive a general edit")
        let tokens = await secrets.tokens
        XCTAssertTrue(tokens.isEmpty, "no token flag ⇒ the stored token is left alone")
    }

    /// The settings form's Save shares this; a pasted token's trailing newline would break auth.
    func testSaveGeneralTrimsANewlineFromAPastedToken() async throws {
        let product = addProduct()
        await ProductSetup.saveGeneral(product, displayName: "P", mirrorEmailsToGitHub: true,
                                       redactEmailAddresses: true, token: " ghp_x\n",
                                       products: products, secrets: secrets.secrets)
        let saved = await secrets.tokens
        XCTAssertEqual(saved.map(\.token), ["ghp_x"])
    }

    func testUpdateWithANewTokenVerifiesAndStoresIt() async throws {
        addProduct()
        _ = try await CLIRequestHandlers.updateProduct(request(.updateProduct, ["product": "P", "token": "fresh"]),
                                                       deps: makeDeps())
        let tokens = await secrets.tokens
        XCTAssertEqual(tokens.map(\.token), ["fresh"])
    }

    func testRemoveDeletesTheProduct() async throws {
        addProduct()
        let response = try await CLIRequestHandlers.removeProduct(request(.removeProduct, ["product": "P"]),
                                                                  deps: makeDeps())
        XCTAssertTrue(products.products.isEmpty)
        XCTAssertTrue(try XCTUnwrap(response.json).contains("removed"))
    }

    // MARK: - products app-store

    func testAppStoreWithSeveralAppsAndNoAppIdAsksWhichAndSavesNothing() async {
        addProduct()
        let client = FakeAppStoreConnectClient()
        client.setApps([ASCApp(id: "1", bundleId: "a.b", name: "Alpha"), ASCApp(id: "2", bundleId: "c.d", name: "Beta")])
        let error = await expectError("app_ambiguous") {
            _ = try await CLIRequestHandlers.configureAppStore(
                self.request(.configureAppStore, ["product": "P", "issuerID": "I", "keyID": "K", "pem": "PEM"]),
                deps: self.makeDeps(self.makeApp(ascClient: client)))
        }
        XCTAssertEqual(error?.candidates.count, 2)
        XCTAssertNil(products.products.first?.appStoreAppAppleID)
        let keys = await secrets.ascKeys
        XCTAssertTrue(keys.isEmpty)
    }

    func testAppStoreSavesTheChosenAppAndTheKey() async throws {
        let product = addProduct()
        let client = FakeAppStoreConnectClient()
        client.setApps([ASCApp(id: "1", bundleId: "a.b", name: "Alpha"), ASCApp(id: "2", bundleId: "c.d", name: "Beta")])
        let response = try await CLIRequestHandlers.configureAppStore(
            request(.configureAppStore, ["product": "P", "issuerID": " I ", "keyID": "K", "pem": "PEM", "appID": "2"]),
            deps: makeDeps(makeApp(ascClient: client)))
        let saved = try XCTUnwrap(products.products.first)
        XCTAssertEqual(saved.appStoreIssuerID, "I")
        XCTAssertEqual(saved.appStoreKeyID, "K")
        XCTAssertEqual(saved.appStoreAppAppleID, "2")
        let keys = await secrets.ascKeys
        XCTAssertEqual(keys.first?.pem, "PEM")
        XCTAssertEqual(keys.first?.productID, product.id)
        XCTAssertEqual(try decode(CLIRequestHandlers.AppStoreSourceResult.self, response).app.name, "Beta")
    }

    func testAppStoreWithARejectedKeyIsAnAuthError() async {
        addProduct()
        let client = FakeAppStoreConnectClient()
        client.setThrowOnList(AppStoreConnectError.authFailed)
        let error = await expectError("auth") {
            _ = try await CLIRequestHandlers.configureAppStore(
                self.request(.configureAppStore, ["product": "P", "issuerID": "I", "keyID": "K", "pem": "PEM"]),
                deps: self.makeDeps(self.makeApp(ascClient: client)))
        }
        XCTAssertTrue(error?.message.contains("Authentication failed") == true)
    }

    // MARK: - products email

    func testEmailTestsTheLoginThenCreatesAndLinksTheInbox() async throws {
        addProduct()
        var tested: [String] = []
        let deps = makeDeps(makeApp(testInbox: { tested.append("\($0.username)@\($0.imapHost)") }))
        _ = try await CLIRequestHandlers.configureEmail(
            request(.configureEmail, ["product": "P", "preset": "icloud", "address": "fb@icloud.com",
                                      "password": "abcd efgh ijkl mnop"]), deps: deps)

        let product = try XCTUnwrap(products.products.first)
        let account = try XCTUnwrap(product.feedbackInboxAccountID.flatMap { mailAccounts.account(id: $0) })
        XCTAssertEqual(tested, ["fb@icloud.com@imap.mail.me.com"])
        XCTAssertEqual(account.imapUsername, "fb@icloud.com")
        XCTAssertEqual(account.feedbackProductID, product.id)
        XCTAssertEqual(account.senderName, "P", "the sender is named after the product, as in the wizard")
        let passwords = await secrets.mailPasswords
        XCTAssertEqual(passwords.first?.password, "abcdefghijklmnop", "app passwords are de-spaced")
    }

    func testEmailWithAFailedLoginSavesNothing() async {
        addProduct()
        let deps = makeDeps(makeApp(testInbox: { _ in throw CLIError.auth(message: "bad password", hint: nil) }))
        _ = await expectError("auth") {
            _ = try await CLIRequestHandlers.configureEmail(
                self.request(.configureEmail, ["product": "P", "preset": "gmail", "address": "a@gmail.com",
                                               "password": "x"]), deps: deps)
        }
        XCTAssertNil(products.products.first?.feedbackInboxAccountID)
        XCTAssertTrue(mailAccounts.accounts.isEmpty)
    }

    func testEmailReconfigureReusesTheExistingInbox() async throws {
        addProduct()
        let deps = makeDeps()
        for address in ["one@gmail.com", "two@gmail.com"] {
            _ = try await CLIRequestHandlers.configureEmail(
                request(.configureEmail, ["product": "P", "preset": "gmail", "address": address, "password": "x"]),
                deps: deps)
        }
        XCTAssertEqual(mailAccounts.accounts.count, 1, "editing must not mint a second account")
        XCTAssertEqual(mailAccounts.accounts.first?.imapUsername, "two@gmail.com")
    }

    func testRemoveEmailUnlinksAndDeletesTheInbox() async throws {
        addProduct()
        let deps = makeDeps()
        _ = try await CLIRequestHandlers.configureEmail(
            request(.configureEmail, ["product": "P", "preset": "gmail", "address": "a@gmail.com", "password": "x"]),
            deps: deps)
        _ = try await CLIRequestHandlers.removeEmail(request(.removeEmail, ["product": "P"]), deps: deps)
        XCTAssertNil(products.products.first?.feedbackInboxAccountID)
        XCTAssertTrue(mailAccounts.accounts.isEmpty)

        _ = await expectError("no_email_source") {
            _ = try await CLIRequestHandlers.removeEmail(self.request(.removeEmail, ["product": "P"]), deps: deps)
        }
    }

    // MARK: - versions

    func testCreateVersionProvisionsItsMilestone() async throws {
        addProduct()
        stubGitHub(status: 201, json: #"{"number":7,"title":"1.2.0","state":"open","description":""}"#)
        let response = try await CLIRequestHandlers.createVersion(
            request(.createVersion, ["product": "P", "version": "1.2.0", "title": "Polish", "changelog": "Faster"]),
            deps: makeDeps())
        let version = try XCTUnwrap(versions.versions(owner: "o", repo: "r").first)
        XCTAssertEqual(version.milestoneNumber, 7)
        XCTAssertEqual(version.releaseTitle, "Polish")
        XCTAssertEqual(requests.all.first?.httpMethod, "POST")
        XCTAssertEqual(try decode(VersionItem.self, response).milestoneNumber, 7)
    }

    /// The app's Dismiss on a failed card, done for the caller so a re-run can succeed.
    func testCreateVersionRollsBackWhenTheMilestoneFails() async {
        addProduct()
        stubGitHub(status: 500)
        _ = await expectError("remote_failure") {
            _ = try await CLIRequestHandlers.createVersion(
                self.request(.createVersion, ["product": "P", "version": "1.2.0"]), deps: self.makeDeps())
        }
        XCTAssertTrue(versions.versions(owner: "o", repo: "r").isEmpty)
    }

    func testCreateVersionRejectsADuplicateName() async throws {
        addProduct()
        try versions.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        let error = await expectError("bad_value") {
            _ = try await CLIRequestHandlers.createVersion(
                self.request(.createVersion, ["product": "P", "version": "1.2.0"]), deps: self.makeDeps())
        }
        XCTAssertEqual(error?.exitCode, .usage)
        XCTAssertTrue(requests.all.isEmpty, "nothing reaches GitHub")
    }

    func testCreateVersionWithoutATokenIsAuth() async {
        addProduct()
        _ = await expectError("auth") {
            _ = try await CLIRequestHandlers.createVersion(
                self.request(.createVersion, ["product": "P", "version": "1.2.0"]), deps: self.makeDeps(token: nil))
        }
        XCTAssertTrue(versions.versions(owner: "o", repo: "r").isEmpty)
    }

    func testUpdateVersionRenamesAndCascadesToCachedTasks() async throws {
        addProduct()
        let version = try versions.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "old")
        version.milestoneNumber = 7
        versions.saveAndReload()
        cache(40, title: "Task", labels: [LoveLetterLabels.task], milestone: "1.2.0")
        stubGitHub(json: #"{"number":7,"title":"1.3.0","state":"open","description":"new"}"#)

        _ = try await CLIRequestHandlers.updateVersion(
            request(.updateVersion, ["product": "P", "version": "1.2.0", "name": "1.3.0",
                                     "changelog": "new", "setChangelog": "1"]), deps: makeDeps())
        XCTAssertEqual(version.name, "1.3.0")
        XCTAssertEqual(version.changelog, "new")
        XCTAssertEqual(requests.all.filter { $0.httpMethod == "PATCH" }.count, 2, "details, then the title")
        let task = try context.fetch(FetchDescriptor<CachedIssue>()).first { $0.number == 40 }
        XCTAssertEqual(task?.milestoneTitle, "1.3.0", "tasks follow the renamed version")
    }

    func testUpdateVersionTitleOnlyLeavesTheChangelog() async throws {
        addProduct()
        let version = try versions.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "keep")
        _ = try await CLIRequestHandlers.updateVersion(
            request(.updateVersion, ["product": "P", "version": "1.2.0", "title": "T", "setTitle": "1"]),
            deps: makeDeps())
        XCTAssertEqual(version.releaseTitle, "T")
        XCTAssertEqual(version.changelog, "keep")
    }

    func testDeleteVersionRemovesTheMilestoneAndTheRecord() async throws {
        addProduct()
        let version = try versions.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        version.milestoneNumber = 7
        versions.saveAndReload()
        stubGitHub(status: 204)
        _ = try await CLIRequestHandlers.deleteVersion(request(.deleteVersion, ["product": "P", "version": "1.2.0"]),
                                                       deps: makeDeps())
        XCTAssertTrue(versions.versions(owner: "o", repo: "r").isEmpty)
        XCTAssertEqual(requests.all.first?.httpMethod, "DELETE")
    }

    func testUnknownVersionListsTheRealOnes() async throws {
        addProduct()
        try versions.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "")
        let error = await expectError("version_not_found") {
            _ = try await CLIRequestHandlers.deleteVersion(
                self.request(.deleteVersion, ["product": "P", "version": "9"]), deps: self.makeDeps())
        }
        XCTAssertEqual(error?.candidates, ["1.2.0"])
    }

    // MARK: - versions release

    /// A done task in the version, linked to two reporters' feedback.
    private func seedRelease() throws -> ProjectVersion {
        addProduct()
        let version = try versions.create(repoOwner: "o", repoName: "r", name: "1.2.0", changelog: "Faster sync")
        version.milestoneNumber = 7
        versions.saveAndReload()
        cache(10, email: "ann@example.com")
        cache(11, email: "ben@example.com")
        cache(40, title: "Fix sync", labels: [LoveLetterLabels.task, "status:done"],
              body: FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 11]), milestone: "1.2.0", state: .closed)
        return version
    }

    func testReleaseEmailsRecipientsThenPublishes() async throws {
        let version = try seedRelease()
        mailAccounts.add { $0.smtpUsername = "me@example.com" }
        versions.recordSent(version: version, recipientEmail: "ben@example.com", feedbackNumbers: [11],
                            threadIssueNumber: 11, status: .sent)
        let mailer = FakeReleaseMailer(versions: versions)
        stubGitHub(status: 201, json: #"{"id":1,"tag_name":"v1.2.0","draft":false,"html_url":"u","number":7,"title":"1.2.0","state":"closed","description":""}"#)

        let response = try await CLIRequestHandlers.releaseVersion(
            request(.releaseVersion, ["product": "P", "version": "1.2.0"]), deps: makeDeps(makeApp(mailer: mailer)))

        XCTAssertEqual(mailer.sent.map(\.email), ["ann@example.com"], "already-emailed reporters are skipped")
        XCTAssertEqual(mailer.templates.first?.subject, "{appName} {version} is out")
        XCTAssertTrue(version.releasePublished)
        XCTAssertTrue(requests.all.contains { $0.url?.path.hasSuffix("/releases") == true },
                      "with a mail account the release is published, as Send & Release does")
        let result = try decode(CLIRequestHandlers.ReleaseResult.self, response)
        XCTAssertEqual(result.emailed, ["a***@example.com"])
        XCTAssertTrue(result.githubRelease)
        XCTAssertEqual(result.tag, "v1.2.0")
    }

    func testReleaseWithRecipientsButNoMailAccountRefusesBeforeReleasing() async throws {
        let version = try seedRelease()
        _ = await expectError("auth") {
            _ = try await CLIRequestHandlers.releaseVersion(
                self.request(.releaseVersion, ["product": "P", "version": "1.2.0"]),
                deps: self.makeDeps(self.makeApp(mailer: FakeReleaseMailer(versions: self.versions))))
        }
        XCTAssertFalse(version.releasePublished)
        XCTAssertTrue(requests.all.isEmpty)
    }

    /// No mail account + --no-email is the app's "Mark released (no email)": the milestone
    /// closes, and no GitHub Release is published.
    func testReleaseNoEmailWithoutAMailAccountIsMarkReleased() async throws {
        let version = try seedRelease()
        stubGitHub(json: #"{"number":7,"title":"1.2.0","state":"closed","description":""}"#)
        let response = try await CLIRequestHandlers.releaseVersion(
            request(.releaseVersion, ["product": "P", "version": "1.2.0", "noEmail": "1"]), deps: makeDeps())
        XCTAssertTrue(version.releasePublished)
        XCTAssertEqual(requests.all.map(\.httpMethod), ["PATCH"])
        XCTAssertFalse(try decode(CLIRequestHandlers.ReleaseResult.self, response).githubRelease)
        XCTAssertTrue(response.warnings.contains { $0.contains("no GitHub release was published") },
                      "an agent reading only `ok` must not report a published release")
    }

    func testReleasingAReleasedVersionIsRefused() async throws {
        let version = try seedRelease()
        version.releasePublished = true
        versions.saveAndReload()
        _ = await expectError("already_released") {
            _ = try await CLIRequestHandlers.releaseVersion(
                self.request(.releaseVersion, ["product": "P", "version": "1.2.0", "noEmail": "1"]),
                deps: self.makeDeps())
        }
    }

    func testRecipientSelectionMirrorsTheReleaseSheet() throws {
        let all = [ReleaseRecipient(email: "ann@x.com", feedbackNumbers: [1]),
                   ReleaseRecipient(email: "ben@x.com", feedbackNumbers: [2]),
                   ReleaseRecipient(email: "cat@x.com", feedbackNumbers: [3])]
        func pick(only: [String] = [], skip: [String] = [], resend: Bool = false) throws -> [String] {
            try CLIRequestHandlers.releaseRecipients(all, alreadySent: ["ben@x.com"], only: only, skip: skip,
                                                     resend: resend, noEmail: false).map(\.email)
        }
        XCTAssertEqual(try pick(), ["ann@x.com", "cat@x.com"])
        XCTAssertEqual(try pick(resend: true), ["ann@x.com", "ben@x.com", "cat@x.com"])
        XCTAssertEqual(try pick(skip: ["CAT@x.com"]), ["ann@x.com"])
        XCTAssertEqual(try pick(only: ["ben@x.com"]), ["ben@x.com"], "naming someone is an explicit resend")
        XCTAssertThrowsError(try pick(only: ["zed@x.com"]))
        XCTAssertEqual(try CLIRequestHandlers.releaseRecipients(all, alreadySent: [], only: [], skip: [],
                                                                resend: false, noEmail: true), [])
    }

    // MARK: - tasks update / delete

    func testUpdateTaskPatchesOnlyWhatChangedAndKeepsTheFeedbackBlock() async throws {
        addProduct()
        await writer.stub(FetchedIssue(number: 40, title: "Old", body: FeedbackTaskRefParser.upsert(into: "notes", refs: [10]),
                                       labels: [LoveLetterLabels.task, "status:todo", "priority:high"], state: "open"))
        stubGitHub()
        let response = try await CLIRequestHandlers.updateTask(
            request(.updateTask, ["product": "P", "task": "40", "status": "in-progress"]), deps: makeDeps())

        let patch = try XCTUnwrap(requests.all.first { $0.httpMethod == "PATCH" })
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(patch.bodyData)) as? [String: Any])
        XCTAssertEqual(sent["title"] as? String, "Old")
        XCTAssertEqual(FeedbackTaskRefParser.parse(sent["body"] as? String ?? ""), [10])
        XCTAssertEqual(Set(sent["labels"] as? [String] ?? []),
                       [LoveLetterLabels.task, "status:in-progress", "priority:high"], "priority kept")
        XCTAssertNil(sent["milestone"], "no --version ⇒ the milestone is not even sent")
        XCTAssertEqual(try decode(TaskDetail.self, response).status, "in-progress")
    }

    func testUpdateTaskNoVersionClearsTheMilestone() async throws {
        addProduct()
        await writer.stub(FetchedIssue(number: 40, title: "T", body: "", labels: [LoveLetterLabels.task], state: "open"))
        stubGitHub()
        _ = try await CLIRequestHandlers.updateTask(
            request(.updateTask, ["product": "P", "task": "40", "noVersion": "1"]), deps: makeDeps())
        let patch = try XCTUnwrap(requests.all.first { $0.httpMethod == "PATCH" })
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(patch.bodyData)) as? [String: Any])
        XCTAssertTrue(sent["milestone"] is NSNull)
    }

    func testUpdateOrDeleteRefusesANonTask() async {
        addProduct()
        await writer.stub(FetchedIssue(number: 10, title: "A report", body: "", labels: ["bug"], state: "open"))
        stubGitHub()
        _ = await expectError("task_not_found") {
            _ = try await CLIRequestHandlers.updateTask(
                self.request(.updateTask, ["product": "P", "task": "10", "title": "x"]), deps: self.makeDeps())
        }
        _ = await expectError("task_not_found") {
            _ = try await CLIRequestHandlers.deleteTask(self.request(.deleteTask, ["product": "P", "task": "10"]),
                                                        deps: self.makeDeps())
        }
        XCTAssertTrue(requests.all.isEmpty, "a feedback issue is never written")
    }

    // MARK: - feedback mark-read

    func testMarkReadMarksOnlyUnseenFeedback() async throws {
        addProduct()
        cache(10); cache(11); cache(40, labels: [LoveLetterLabels.task])
        SeenIssueStore(context: context).markSeen(owner: "o", repo: "r", issueNumber: 11)
        let response = try await CLIRequestHandlers.markRead(request(.markRead, ["product": "P", "all": "1"]),
                                                             deps: makeDeps())
        let result = try decode(CLIRequestHandlers.MarkReadResult.self, response)
        XCTAssertEqual(result.marked, [10], "tasks aren't feedback; #11 was already read")
        XCTAssertEqual(result.alreadyRead, 1)
        XCTAssertEqual(SeenIssueStore(context: context).seenNumbers(owner: "o", repo: "r"), [10, 11])
    }

    func testMarkReadRejectsAnUncachedNumber() async {
        addProduct()
        cache(10)
        _ = await expectError("feedback_not_found") {
            _ = try await CLIRequestHandlers.markRead(self.request(.markRead, ["product": "P", "feedback": "10,99"]),
                                                      deps: self.makeDeps())
        }
    }

    // MARK: - feedback triage

    func testTriageDismissesAPendingSuggestion() async throws {
        addProduct()
        let store = TriageVerdictStore(context: context)
        let coordinator = FeedbackTriageCoordinator(
            provider: MockIntelligenceProvider(), store: store,
            settings: TriageSettings(defaults: UserDefaults(suiteName: "cli-triage-\(UUID())")!),
            applier: MockTriageApplier())
        let record = store.upsert(owner: "o", repo: "r", number: 10) { $0.suggestedTaskNumber = 40 }
        let deps = makeDeps(makeApp(triage: coordinator))

        _ = try await CLIRequestHandlers.triage(request(.triage, ["product": "P", "feedback": "10", "action": "dismiss"]),
                                                deps: deps)
        XCTAssertEqual(record.state, TriageState.dismissed.rawValue)

        _ = await expectError("no_triage_suggestion") {
            _ = try await CLIRequestHandlers.triage(
                self.request(.triage, ["product": "P", "feedback": "10", "action": "accept"]), deps: deps)
        }
    }

    // MARK: - templates

    func testTemplateLifecycle() async throws {
        addProduct()
        let deps = makeDeps()
        _ = try await CLIRequestHandlers.createTemplate(
            request(.createTemplate, ["product": "P", "title": "Thanks", "body": "Thank you!"]), deps: deps)
        _ = await expectError("template_exists") {
            _ = try await CLIRequestHandlers.createTemplate(
                self.request(.createTemplate, ["product": "P", "title": "thanks", "body": "dup"]), deps: deps)
        }
        _ = try await CLIRequestHandlers.updateTemplate(
            request(.updateTemplate, ["product": "P", "template": "THANKS", "body": "Thanks a lot!"]), deps: deps)
        XCTAssertEqual(templates.templates(owner: "o", repo: "r").map(\.body), ["Thanks a lot!"])
        XCTAssertEqual(templates.templates(owner: "o", repo: "r").map(\.title), ["Thanks"], "title untouched")

        _ = try await CLIRequestHandlers.deleteTemplate(
            request(.deleteTemplate, ["product": "P", "template": "Thanks"]), deps: deps)
        XCTAssertTrue(templates.templates(owner: "o", repo: "r").isEmpty)
    }

    // MARK: - Dispatch

    /// Every request kind the CLI can send reaches a handler, rather than the generic failure.
    func testWritesWithoutAppDependenciesSayTheyAreUnavailable() async {
        var deps = makeDeps()
        deps.app = nil
        addProduct()
        _ = await expectError("remote_failure") {
            _ = try await CLIRequestHandlers.handle(self.request(.removeProduct, ["product": "P"]), deps: deps)
        }
        XCTAssertEqual(products.products.count, 1)
    }

    // MARK: - Read-side queries share the handlers' view

    func testVersionDetailListsRecipientsRedactedAndFlagsAlreadyEmailed() throws {
        let version = try seedRelease()
        versions.recordSent(version: version, recipientEmail: "ben@example.com", feedbackNumbers: [11],
                            threadIssueNumber: 11, status: .sent)
        let config = try XCTUnwrap(products.products.first)
        let detail = VersionQuery.detail(version, config: config, local: context, cloud: context, includeEmails: false)
        XCTAssertEqual(detail.version.state, "wip")
        XCTAssertEqual(detail.version.doneCount, 1)
        XCTAssertEqual(detail.recipients.map(\.email), ["a***@example.com", "b***@example.com"])
        XCTAssertEqual(detail.recipients.map(\.alreadyEmailed), [false, true])
        XCTAssertEqual(detail.sentEmails.count, 1)
        XCTAssertEqual(detail.releaseRepo, "o/r")
    }

    func testTemplateAndAccountQueries() async throws {
        let product = addProduct()
        templates.create(owner: "o", repo: "r", title: "Hi", body: "Hello")
        connect("octocat")
        mailAccounts.add { $0.imapUsername = "fb@x.com"; $0.feedbackProductID = product.id }

        XCTAssertEqual(TemplateQuery.templates(config: product, cloud: context).map(\.title), ["Hi"])
        let accounts = AccountsQuery.run(cloud: context)
        XCTAssertEqual(accounts.github.map(\.login), ["octocat"])
        XCTAssertEqual(accounts.mail.first?.address, "fb@x.com")
        XCTAssertEqual(accounts.mail.first?.feedbackInboxFor, "P")
    }
}

// MARK: - Fakes

/// Records every secret product setup writes.
private actor SecretStore {
    var tokens: [(token: String, productID: UUID)] = []
    var ascKeys: [(pem: String, productID: UUID)] = []
    var mailPasswords: [(password: String, accountID: UUID)] = []
    func token(_ token: String, _ id: UUID) { tokens.append((token, id)) }
    func ascKey(_ pem: String, _ id: UUID) { ascKeys.append((pem, id)) }
    func mailPassword(_ password: String, _ id: UUID) { mailPasswords.append((password, id)) }
}

private final class SecretRecorder: Sendable {
    private let store = SecretStore()
    var tokens: [(token: String, productID: UUID)] { get async { await store.tokens } }
    var ascKeys: [(pem: String, productID: UUID)] { get async { await store.ascKeys } }
    var mailPasswords: [(password: String, accountID: UUID)] { get async { await store.mailPasswords } }

    var secrets: ProductSecrets {
        let store = self.store
        return ProductSecrets(saveToken: { await store.token($0, $1.id) },
                              saveASCKey: { await store.ascKey($0, $1) },
                              saveMailPassword: { await store.mailPassword($0, $1) })
    }
}

private final class RequestLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    func append(_ request: URLRequest) { lock.withLock { $0.append(request) } }
    var all: [URLRequest] { lock.withLock { $0 } }
}

/// Records release sends and writes the rows `ReleaseNotificationService` would.
@MainActor
private final class FakeReleaseMailer: ReleaseMailing {
    let versions: VersionStore
    private(set) var sent: [ReleaseRecipient] = []
    private(set) var templates: [ReleaseEmailTemplate] = []
    init(versions: VersionStore) { self.versions = versions }

    func send(repo: ProductConfig, version: ProjectVersion, recipients: [ReleaseRecipient],
              feedback: [FeedbackIssue], template: ReleaseEmailTemplate, appName: String,
              onProgress: @escaping (Int, Int) -> Void) async {
        sent += recipients
        templates.append(template)
        for recipient in recipients {
            versions.recordSent(version: version, recipientEmail: recipient.email,
                                feedbackNumbers: recipient.feedbackNumbers,
                                threadIssueNumber: recipient.feedbackNumbers.first ?? 0, status: .sent)
        }
    }
}

private extension URLRequest {
    /// URLProtocol hands over a stream, not `httpBody`.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
#endif

private actor CreatedRepos {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}
