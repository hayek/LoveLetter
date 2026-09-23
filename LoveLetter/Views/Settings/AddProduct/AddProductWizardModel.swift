import Foundation
import Observation

/// State + step logic behind `AddProductWizard`. Every source (the SDK, App Store reviews, an
/// email inbox) gets its own step that the user either sets up or skips, so a product can collect
/// feedback from any combination of them. Every product still needs a GitHub repository: it's
/// where each source files its feedback as issues.
@MainActor
@Observable
final class AddProductWizardModel {
    enum Source: String, CaseIterable, Identifiable {
        case sdk, appStore, email
        var id: String { rawValue }
    }

    enum Step: Hashable, CaseIterable {
        case repository, sdk, appStore, email, summary

        /// The source a step sets up; nil for the required repository step and the summary.
        var source: Source? {
            switch self {
            case .sdk:      .sdk
            case .appStore: .appStore
            case .email:    .email
            case .repository, .summary: nil
            }
        }
    }

    /// Minted up front so the email inbox account can reference the product before it exists.
    let productID = UUID()

    /// The sources set up so far: a source step's Continue adds it, Skip removes it.
    private(set) var sources: Set<Source> = []
    private(set) var step: Step = .repository
    /// Direction of the last move, so the view can slide steps in from the matching edge.
    private(set) var movedForward = true

    // Repository
    enum RepositoryMode: Hashable { case existing, new }

    /// Pick one of the account's repositories, or create a new one on Create Product. Switching
    /// clears the choice, so a half-picked repo never carries over into the other mode.
    var repositoryMode: RepositoryMode = .existing {
        didSet {
            guard repositoryMode != oldValue else { return }
            owner = ""; repo = ""; token = ""; newRepoError = nil
            repoIsPrivate = repositoryMode == .new ? true : nil
            newRepoOwnerIsOrganization = false
        }
    }
    /// For `.existing` the picked repo; for `.new` the owner and name to create. Any change
    /// invalidates the last name check.
    var owner = "" { didSet { if owner != oldValue { clearNewRepoCheck() } } }
    var repo = "" { didSet { if repo != oldValue { clearNewRepoCheck() } } }
    var token = "" { didSet { if token != oldValue { clearNewRepoCheck() } } }
    /// Known when the repo was picked from an account or is being created; nil for manual entry.
    var repoIsPrivate: Bool?
    var newRepoOwnerIsOrganization = false
    /// Why the new repository's name can't be used, or why it couldn't be checked, from the check
    /// Continue runs. Only a taken name blocks Continue; a failed check can simply be retried.
    private(set) var newRepoError: String?
    private(set) var newRepoNameTaken = false
    private(set) var isCheckingNewRepo = false
    /// "owner/repo" (lowercased) of the repository Create Product already made, so a retry
    /// doesn't try to create it again and fail on its own name.
    private var createdRepoKey: String?

    /// The connected account the repository step shows, and its repository lists. Kept here
    /// rather than in the step's view, which is rebuilt each time the user comes back to it.
    var accountID: UUID?
    var accountRepos: [UUID: AccountRepos] = [:]

    enum AccountRepos {
        case loading, loaded([GitHubRepo]), failed(String), expired
    }

    var createsRepository: Bool { repositoryMode == .new }
    /// "owner/repo" (lowercased) of products that already exist.
    var existingRepoKeys: Set<String> = []

    // Sources
    let appStore = AppStoreSourceFormModel()
    let email: EmailSourceFormModel

    // Summary
    var name = ""
    var colorHex: String?
    /// The name the summary step last filled in, so a later visit can refresh it (e.g. after
    /// going back to pick an App Store app) without overwriting a name the user typed.
    private var prefilledName: String?

    init() {
        email = EmailSourceFormModel(productID: productID, existingAccountID: nil)
    }

    // MARK: - Steps

    let steps = Step.allCases

    var stepNumber: Int { (steps.firstIndex(of: step) ?? 0) + 1 }
    var isFirstStep: Bool { step == steps.first }
    var isLastStep: Bool { step == .summary }
    var canSkip: Bool { step.source != nil }

    var canContinue: Bool {
        switch step {
        case .repository:
            hasRepository && !isDuplicateRepository && !isCheckingNewRepo
                && (!createsRepository || (ProductSetup.isValidRepositoryName(trimmed(repo)) && !newRepoNameTaken))
        case .appStore:   appStore.canSave
        case .email:      email.canTest
        case .sdk:        true
        case .summary:    true // an empty name falls back to `suggestedName`
        }
    }

    func goForward() {
        guard canContinue else { return }
        if let source = step.source { sources.insert(source) }
        advance()
    }

    func skip() {
        guard let source = step.source else { return }
        sources.remove(source)
        advance()
    }

    private func advance() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        movedForward = true
        step = steps[index + 1]
        if step == .summary && (trimmed(name).isEmpty || name == prefilledName) {
            name = suggestedName
            prefilledName = name
        }
    }

    /// Run by Continue on the repository step when creating one: makes sure the name is free on
    /// GitHub, so a clash shows here rather than after every other step. True when it's free.
    /// A change made while the check runs (the mode and account stay switchable) voids its answer: false,
    /// with no error, so the next Continue checks what's there now.
    func verifyNewRepository(service: ProductSetup.RepositoryService = .github) async -> Bool {
        guard step == .repository, createsRepository, canContinue else { return false }
        let checked = [trimmed(owner), trimmed(repo), trimmed(token)]
        isCheckingNewRepo = true
        defer { isCheckingNewRepo = false }
        let result: Result<Bool, Error>
        do { result = .success(try await service.exists(checked[0], checked[1], checked[2])) }
        catch { result = .failure(error) }
        guard step == .repository, createsRepository,
              [trimmed(owner), trimmed(repo), trimmed(token)] == checked else { return false }
        switch result {
        case .success(true):
            newRepoError = "\(repoFullName) already exists. Choose another name, or pick it under Existing."
            newRepoNameTaken = true
            return false
        case .success(false):
            return true
        case .failure(let error):
            newRepoError = "Couldn't check the name on GitHub: \(error.localizedDescription)"
            return false
        }
    }

    private func clearNewRepoCheck() {
        newRepoError = nil
        newRepoNameTaken = false
    }

    func goBack() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        movedForward = false
        step = steps[index - 1]
    }

    // MARK: - Derived values

    var hasRepository: Bool {
        !trimmed(owner).isEmpty && !trimmed(repo).isEmpty && !trimmed(token).isEmpty
    }

    /// "owner/repo", trimmed.
    var repoFullName: String { "\(trimmed(owner))/\(trimmed(repo))" }

    var isDuplicateRepository: Bool {
        existingRepoKeys.contains(repoFullName.lowercased())
    }

    var selectedRepoKey: String? {
        hasRepository ? repoFullName.lowercased() : nil
    }

    /// The numeric Apple ID fallback is offered when the key couldn't list any apps to pick from.
    var appStoreNeedsManualAppID: Bool {
        switch appStore.phase {
        case .failed: true
        case .valid:  appStore.discoveredApps.isEmpty
        case .idle, .testing: false
        }
    }

    /// The App Store app the user picked, when the key was verified.
    var selectedApp: ASCApp? {
        guard sources.contains(.appStore), let id = appStore.resolvedAppAppleID() else { return nil }
        return appStore.discoveredApps.first { $0.id == id }
    }

    /// The App Store app name when there is one (it's the product's real name), else the repo name.
    var suggestedName: String {
        selectedApp?.name ?? trimmed(repo)
    }

    /// The name the product is saved with.
    var displayName: String {
        trimmed(name).isEmpty ? suggestedName : trimmed(name)
    }

    /// The product as it will be saved. Source secrets (token, .p8, inbox password) are stored
    /// separately by `create`; the email inbox id is attached once its account exists.
    func makeConfig(feedbackInboxAccountID: UUID? = nil) -> ProductConfig {
        let usesAppStore = sources.contains(.appStore)
        return ProductConfig(
            id: productID,
            displayName: displayName,
            owner: trimmed(owner),
            repo: trimmed(repo),
            // Redact addresses in mirrored comments unless the repo is known to be private.
            redactEmailAddresses: repoIsPrivate != true,
            colorHex: colorHex,
            appStoreIssuerID: usesAppStore ? trimmed(appStore.issuerID) : nil,
            appStoreKeyID: usesAppStore ? trimmed(appStore.keyID) : nil,
            appStoreAppAppleID: usesAppStore ? appStore.resolvedAppAppleID() : nil,
            feedbackInboxAccountID: sources.contains(.email) ? feedbackInboxAccountID : nil
        )
    }

    /// Saves the product, its secrets and (when set up) its email inbox through
    /// `ProductSetup.create` — the same writes `loveletter products add` makes. An inbox with no
    /// sender name is named after the product. A new repository is created on GitHub first; if
    /// that fails nothing is saved.
    @discardableResult
    func create(products: ProductStore, mailAccounts: MailAccountStore,
                mailRegistry: MailSyncCoordinatorRegistry?,
                secrets: ProductSecrets = .keychain,
                repositories: ProductSetup.RepositoryService = .github) async throws -> ProductConfig {
        if createsRepository && createdRepoKey != repoFullName.lowercased() {
            let new = ProductSetup.NewRepository(owner: trimmed(owner), ownerIsOrganization: newRepoOwnerIsOrganization,
                                                 name: trimmed(repo), isPrivate: repoIsPrivate ?? true)
            do {
                try await ProductSetup.createRepository(new, productName: displayName, token: trimmed(token),
                                                        service: repositories)
                createdRepoKey = repoFullName.lowercased()
            } catch ProductSetup.CreateRepositoryError.nameTaken(let fullName) {
                // Taken since Continue checked it: say so on the repository step too.
                newRepoError = "\(fullName) already exists. Choose another name, or pick it under Existing."
                newRepoNameTaken = true
                throw ProductSetup.CreateRepositoryError.nameTaken(fullName)
            }
        }
        var inbox: ProductSetup.EmailInbox?
        if sources.contains(.email) {
            if email.senderName.isEmpty { email.senderName = displayName }
            inbox = .init(values: email.effectiveAccountValues(), password: email.password)
        }
        return await ProductSetup.create(makeConfig(), token: token,
                                         ascPEM: sources.contains(.appStore) ? appStore.pemText : nil,
                                         emailInbox: inbox, products: products, mailAccounts: mailAccounts,
                                         mailRegistry: mailRegistry, secrets: secrets)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
