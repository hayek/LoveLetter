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
    var owner = ""
    var repo = ""
    var token = ""
    /// Set when the repo is picked from a connected account; nil for manual entry.
    var repoIsPrivate: Bool?
    /// "owner/repo" (lowercased) of products that already exist.
    var existingRepoKeys: Set<String> = []

    // Sources
    let appStore = AppStoreSourceFormModel()
    let email: EmailSourceFormModel

    // Summary
    var name = ""
    var colorHex: String?

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
        case .repository: hasRepository && !isDuplicateRepository
        case .appStore:   appStore.canSave
        case .email:      email.canTest
        case .sdk:        true
        case .summary:    !trimmed(name).isEmpty
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
        if step == .summary && trimmed(name).isEmpty { name = suggestedName }
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

    var isDuplicateRepository: Bool {
        existingRepoKeys.contains("\(trimmed(owner))/\(trimmed(repo))".lowercased())
    }

    var selectedRepoKey: String? {
        hasRepository ? "\(trimmed(owner))/\(trimmed(repo))".lowercased() : nil
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

    /// The product as it will be saved. Source secrets (token, .p8, inbox password) are stored
    /// separately by the view; the email inbox id is attached once its account exists.
    func makeConfig(feedbackInboxAccountID: UUID? = nil) -> ProductConfig {
        let usesAppStore = sources.contains(.appStore)
        return ProductConfig(
            id: productID,
            displayName: trimmed(name).isEmpty ? suggestedName : trimmed(name),
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

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
