import Foundation

/// Where product setup writes its secrets. Production is the Keychain; tests inject recorders,
/// because the test host has no usable Keychain.
struct ProductSecrets: Sendable {
    var saveToken: @Sendable (String, ProductConfig) async -> Void
    var saveASCKey: @Sendable (String, UUID) async -> Void
    /// One password serves both IMAP and SMTP for a feedback inbox.
    var saveMailPassword: @Sendable (String, UUID) async -> Void

    static let keychain = ProductSecrets(
        saveToken: { token, product in await KeychainService.save(token: token, for: product) },
        saveASCKey: { pem, productID in _ = await KeychainService.saveASCKey(pem, for: productID) },
        saveMailPassword: { password, accountID in
            _ = await KeychainService.saveIMAPPassword(password, for: accountID)
            _ = await KeychainService.saveSMTPPassword(password, for: accountID)
        })
}

/// The writes behind setting up a product: creating it, editing its general settings, and
/// connecting or removing its App Store and email sources. The product settings forms and the
/// CLI both call these, so a product configured from a terminal is saved exactly as one set up
/// by hand. `create` is the Add Product wizard's `create()`, step for step.
@MainActor
enum ProductSetup {

    /// A feedback inbox to create alongside the product.
    struct EmailInbox {
        var values: EmailSourceFormModel.AccountValues
        var password: String
    }

    /// Creates a product. Secrets are written first, so the loaders and coordinators that react
    /// to the new product find them. `product.feedbackInboxAccountID` is ignored; it's set from
    /// the inbox created here. Returns the product as saved.
    @discardableResult
    static func create(_ product: ProductConfig, token: String, ascPEM: String? = nil,
                       emailInbox: EmailInbox? = nil,
                       products: ProductStore, mailAccounts: MailAccountStore,
                       mailRegistry: MailSyncCoordinatorRegistry?,
                       secrets: ProductSecrets = .keychain) async -> ProductConfig {
        var product = product
        product.feedbackInboxAccountID = nil
        if let emailInbox {
            let account = mailAccounts.add { apply(emailInbox.values, to: $0) }
            await secrets.saveMailPassword(emailInbox.password, account.id)
            product.feedbackInboxAccountID = account.id
        }
        if let ascPEM, product.appStoreAppAppleID != nil {
            await secrets.saveASCKey(ascPEM, product.id)
        }
        await secrets.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines), product)
        products.add(product)
        if product.feedbackInboxAccountID != nil { mailRegistry?.syncWithAccounts() }
        return product
    }

    /// The General section's Save: display name, mirror/redact toggles, and (when given) a new
    /// token. Mirrors `ProductSettingsView.save()`.
    static func saveGeneral(_ product: ProductConfig, displayName: String, mirrorEmailsToGitHub: Bool,
                            redactEmailAddresses: Bool, token: String?,
                            products: ProductStore, secrets: ProductSecrets = .keychain) async {
        var updated = product
        updated.displayName = displayName.trimmingCharacters(in: .whitespaces)
        updated.mirrorEmailsToGitHub = mirrorEmailsToGitHub
        updated.redactEmailAddresses = redactEmailAddresses
        // Newlines too: a pasted token often carries one, and GitHub rejects it with it.
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            await secrets.saveToken(token, updated)
        }
        products.update(updated)
    }

    /// Stores the .p8 (keyed by product id), writes the key and app ids onto the product, and
    /// restarts its App Store coordinator so the new credentials take effect immediately.
    static func saveAppStoreSource(productID: UUID, issuerID: String, keyID: String, pem: String,
                                   appAppleID: String, products: ProductStore,
                                   registry: AppStoreReviewCoordinatorRegistry?,
                                   secrets: ProductSecrets = .keychain) async {
        await secrets.saveASCKey(pem, productID)
        guard var product = products.products.first(where: { $0.id == productID }) else { return }
        product.appStoreIssuerID = issuerID.trimmingCharacters(in: .whitespaces)
        product.appStoreKeyID = keyID.trimmingCharacters(in: .whitespaces)
        product.appStoreAppAppleID = appAppleID
        products.update(product)
        registry?.restart(productID: productID, configs: ascConfigs(products.products))
    }

    /// The products the App Store registry should poll: those with all three App Store fields.
    static func ascConfigs(_ products: [ProductConfig]) -> [ASCProductConfig] {
        products.compactMap {
            ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                  issuerID: $0.appStoreIssuerID, keyID: $0.appStoreKeyID,
                                  appAppleID: $0.appStoreAppAppleID)
        }
    }

    /// Creates or updates the product's feedback-inbox account and points the product at it.
    /// `existingAccountID` is the inbox being edited; when nil, an inbox the product already
    /// links to is reused rather than minting a second account. Returns the account id.
    @discardableResult
    static func persistEmailSource(product: ProductConfig, values: EmailSourceFormModel.AccountValues,
                                   password: String, existingAccountID: UUID?,
                                   products: ProductStore, mailAccounts: MailAccountStore,
                                   mailRegistry: MailSyncCoordinatorRegistry?,
                                   secrets: ProductSecrets = .keychain) async -> UUID {
        let accountID: UUID
        let linked = products.products.first(where: { $0.id == product.id })?.feedbackInboxAccountID
        if let existing = existingAccountID ?? linked, mailAccounts.account(id: existing) != nil {
            mailAccounts.update(id: existing) { apply(values, to: $0) }
            accountID = existing
        } else {
            accountID = mailAccounts.add { apply(values, to: $0) }.id
        }
        await secrets.saveMailPassword(password, accountID)
        var updated = products.products.first(where: { $0.id == product.id }) ?? product
        updated.feedbackInboxAccountID = accountID
        products.update(updated)
        mailRegistry?.syncWithAccounts()
        return accountID
    }

    /// Unlinks the product's inbox and deletes the account with its credentials. Existing
    /// feedback issues stay on GitHub.
    static func removeEmailSource(product: ProductConfig, accountID: UUID?,
                                  products: ProductStore, mailAccounts: MailAccountStore,
                                  mailRegistry: MailSyncCoordinatorRegistry?) async {
        var updated = products.products.first(where: { $0.id == product.id }) ?? product
        updated.feedbackInboxAccountID = nil
        products.update(updated)
        if let accountID, let account = mailAccounts.account(id: accountID) {
            await mailAccounts.deleteWithCredentials(account)
        }
        mailRegistry?.syncWithAccounts()
    }

    static func apply(_ values: EmailSourceFormModel.AccountValues, to account: MailAccount) {
        account.presetRaw = values.presetRaw
        account.imapHost = values.imapHost; account.imapPort = values.imapPort
        account.imapUsername = values.imapUsername
        account.smtpHost = values.smtpHost; account.smtpPort = values.smtpPort
        account.smtpUsername = values.smtpUsername
        account.senderName = values.senderName
        account.pollingEnabled = values.pollingEnabled
        account.feedbackProductID = values.feedbackProductID
    }

    // MARK: - New feedback repository

    /// A GitHub repository to create for a product's feedback.
    struct NewRepository: Equatable {
        var owner: String
        /// True when `owner` is an organization rather than the token's own user.
        var ownerIsOrganization: Bool
        var name: String
        var isPrivate: Bool
    }

    /// The labels the Love Letter SDKs apply to the issues they file, with GitHub's colors.
    static let feedbackLabels: [(name: String, color: String)] = [
        ("bug", "d73a4a"), ("feature-request", "a2eeef"), ("user-submitted", "c5def5"),
    ]

    /// GitHub name rules: letters, digits, `-`, `_` and `.`, up to 100 characters, not `.` or `..`.
    nonisolated static func isValidRepositoryName(_ name: String) -> Bool {
        guard (1...100).contains(name.count), name != ".", name != ".." else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// The GitHub calls behind creating a feedback repository; tests inject fakes.
    struct RepositoryService: Sendable {
        /// Whether `owner/name` exists (or is otherwise visible to the token).
        var exists: @Sendable (_ owner: String, _ name: String, _ token: String) async throws -> Bool
        /// Returns the repository as GitHub created it, so callers needn't read it back (a
        /// just-created repo can take a moment to show up in reads).
        var create: @Sendable (NewRepository, _ description: String, _ token: String) async throws -> GitHubRepo
        var ensureLabel: @Sendable (_ name: String, _ color: String, _ owner: String, _ repo: String,
                                    _ token: String) async throws -> Void

        static let github = RepositoryService(
            exists: { owner, name, token in
                do {
                    _ = try await GitHubAuthService().fetchRepo(owner: owner, repo: name, token: token)
                    return true
                } catch GitHubAuthService.AuthError.apiError(404) {
                    return false
                }
            },
            create: { new, description, token in
                try await GitHubAuthService().createRepo(
                    name: new.name, organization: new.ownerIsOrganization ? new.owner : nil,
                    isPrivate: new.isPrivate, description: description, token: token)
            },
            ensureLabel: { name, color, owner, repo, token in
                try await GitHubAuthService().ensureLabel(name, color: color, owner: owner, repo: repo, token: token)
            })
    }

    /// Why GitHub wouldn't create a repository, in words for the wizard and the CLI.
    enum CreateRepositoryError: LocalizedError, Equatable {
        case nameTaken(String)
        /// 403/404: the token's user can't create repositories under `owner` (not a member, or
        /// the organization restricts repository creation).
        case notAllowed(owner: String)
        /// Any other validation failure, in GitHub's words.
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .nameTaken(let fullName): "\(fullName) already exists on GitHub."
            case .notAllowed(let owner):   "GitHub didn't allow creating a repository in '\(owner)'."
            case .rejected(let message):   "GitHub rejected the repository: \(message)"
            }
        }
    }

    /// Creates the repository with the SDK's labels. `productName` goes into its description.
    /// Only the repository itself must succeed: a missing label is cosmetic, and failing after the
    /// repo exists would leave the user unable to retry under the same name.
    @discardableResult
    static func createRepository(_ new: NewRepository, productName: String, token: String,
                                 service: RepositoryService = .github) async throws -> GitHubRepo {
        let created: GitHubRepo
        do {
            created = try await service.create(new, "User feedback for \(productName), collected by Love Letter.", token)
        } catch GitHubAuthService.AuthError.apiError(let code) where code == 403 || code == 404 {
            throw CreateRepositoryError.notAllowed(owner: new.owner)
        } catch GitHubAuthService.AuthError.apiError(422) {
            throw CreateRepositoryError.nameTaken("\(new.owner)/\(new.name)")
        } catch let error as GitHubAuthService.ValidationFailed {
            throw error.message.localizedCaseInsensitiveContains("already exists")
                ? CreateRepositoryError.nameTaken("\(new.owner)/\(new.name)")
                : CreateRepositoryError.rejected(error.message)
        }
        for label in feedbackLabels {
            try? await service.ensureLabel(label.name, label.color, created.owner.login, created.name, token)
        }
        return created
    }
}
