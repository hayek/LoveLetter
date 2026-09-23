#if os(macOS)
import Foundation
import SwiftData

/// `products add|update|remove|app-store|email` — the app side. Each one runs the same
/// `ProductSetup` call as the matching settings screen.
extension CLIRequestHandlers {

    static func requireApp(_ deps: Dependencies) throws -> AppDependencies {
        guard let app = deps.app else {
            throw CLIError.remote(message: "This command is unavailable in this build of Love Letter.")
        }
        return app
    }

    /// The live product from the app's store: a resolved config is a snapshot, and writing one
    /// back would revert anything changed since it was read.
    static func liveProduct(_ request: CLIRequest, deps: Dependencies,
                            app: AppDependencies) throws -> ProductConfig {
        let config = try resolveConfig(request, cloud: deps.cloud)
        return app.products.products.first { $0.id == config.id } ?? config
    }

    static func summary(of productID: UUID, deps: Dependencies) -> ProductSummary? {
        ProductResolver.all(cloud: deps.cloud, local: deps.local).first { $0.id == productID.uuidString }
    }

    /// Starts (or stops) the product's GitHub loader and App Store coordinator now. The windows
    /// do this too when they notice the change, but the CLI must not depend on a window being open.
    static func syncRegistries(deps: Dependencies, app: AppDependencies) {
        deps.registry.syncWithProducts(app.products.products)
        app.appStoreRegistry?.syncWithProducts(ProductSetup.ascConfigs(app.products.products))
    }

    // MARK: - add

    static func addProduct(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        guard let (owner, repo) = CLIInvocation.parseRepo(request.payload["repo"] ?? "") else {
            throw CLIError.usage(CLIUsageError(code: "bad_value", message: "--repo must look like owner/repo"))
        }
        let key = "\(owner)/\(repo)".lowercased()
        if let existing = app.products.products.first(where: { "\($0.owner)/\($0.repo)".lowercased() == key }) {
            throw CLIError.usage(CLIUsageError(
                code: "product_exists", message: "\(owner)/\(repo) is already the product '\(existing.displayName)'.",
                hint: "Use `\(CLIBranding.commandName) products update --product \(existing.id.uuidString)`."))
        }

        let resolved: (String, GitHubRepo)
        if let visibility = request.payload["create"], !visibility.isEmpty {
            resolved = try await createRepository(request, owner: owner, repo: repo,
                                                  isPrivate: visibility != "public", app: app)
        } else {
            resolved = try await resolveToken(request, owner: owner, repo: repo, app: app)
        }
        let (token, seen) = resolved
        let name = (request.payload["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let color = request.payload["color"].flatMap { $0.isEmpty ? nil : $0 }
        // Same default as the wizard: redact sender addresses unless the repo is known private.
        let redact = request.payload["redact"].map { $0 == "on" } ?? (seen.isPrivate != true)
        let product = ProductConfig(displayName: name.isEmpty ? seen.name : name,
                                    owner: seen.owner.login, repo: seen.name,
                                    redactEmailAddresses: redact, colorHex: color)
        let saved = await ProductSetup.create(product, token: token, products: app.products,
                                              mailAccounts: app.mailAccounts, mailRegistry: app.mailRegistry,
                                              secrets: app.secrets)
        syncRegistries(deps: deps, app: app)
        guard let result = summary(of: saved.id, deps: deps) else {
            return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(ProductResolver.ref(saved)))
        }
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(result))
    }

    /// The token to store, proven against the repository. A piped token or a named account is
    /// used as given; with neither, the first connected account that can see the repo wins —
    /// the CLI's version of picking the repo from an account in the wizard.
    static func resolveToken(_ request: CLIRequest, owner: String, repo: String,
                             app: AppDependencies) async throws -> (String, GitHubRepo) {
        func token(of account: GitHubAccount) -> String? {
            app.accountToken?(account) ?? app.gitHubAccounts.token(for: account)
        }
        let logins = app.gitHubAccounts.accounts.map(\.login)

        if let piped = request.payload["token"], !piped.isEmpty {
            return (piped, try await probe(owner: owner, repo: repo, token: piped, source: "The token", app: app))
        }
        if let login = request.payload["account"], !login.isEmpty {
            guard let account = app.gitHubAccounts.accounts.first(where: {
                $0.login.compare(login, options: .caseInsensitive) == .orderedSame
            }) else {
                throw CLIError.notFound(code: "account_not_found",
                                        message: "No GitHub account '\(login)' is connected to Love Letter.",
                                        hint: "Connect it in Settings, or pipe a token with --token-stdin.",
                                        candidates: logins)
            }
            guard let secret = token(of: account) else { throw noAccountToken(account.login) }
            return (secret, try await probe(owner: owner, repo: repo, token: secret,
                                            source: "GitHub account '\(account.login)'", app: app))
        }

        let usable = app.gitHubAccounts.accounts.compactMap { account in token(of: account).map { (account, $0) } }
        guard !usable.isEmpty else {
            throw CLIError.usage(CLIUsageError(
                code: "missing_flag", message: "No GitHub token: no GitHub account is connected to Love Letter.",
                hint: "Pipe a token with --token-stdin (it needs read and write access to the repo's issues)."))
        }
        for (_, secret) in usable {
            if let seen = try? await app.fetchRepo(owner, repo, secret) { return (secret, seen) }
        }
        throw CLIError.auth(message: "None of the connected GitHub accounts can see \(owner)/\(repo).",
                            hint: "Check the name, pass --account, or pipe a token with --token-stdin. "
                                + "Connected: \(logins.joined(separator: ", ")).")
    }

    /// `--create-repo`: creates `owner/repo` (with the SDK's labels) using the piped token, the
    /// named account, or the connected account whose login or organizations match `owner` — the
    /// same repository the wizard's New Repository creates.
    static func createRepository(_ request: CLIRequest, owner: String, repo: String, isPrivate: Bool,
                                 app: AppDependencies) async throws -> (String, GitHubRepo) {
        func accountToken(_ account: GitHubAccount) -> String? {
            app.accountToken?(account) ?? app.gitHubAccounts.token(for: account)
        }
        let token: String
        let login: String
        if let piped = request.payload["token"], !piped.isEmpty {
            token = piped
            do { login = try await app.tokenLogin(piped) } catch {
                throw CLIError.auth(message: "The token was rejected by GitHub.", hint: "It may be expired or revoked.")
            }
        } else {
            let named = request.payload["account"].flatMap { $0.isEmpty ? nil : $0 }
            let candidates = app.gitHubAccounts.accounts.filter { account in
                named.map { account.login.compare($0, options: .caseInsensitive) == .orderedSame } ?? true
            }
            // Prefer the account that is the owner; otherwise the first one (it may be an org member).
            guard let account = candidates.first(where: { $0.login.caseInsensitiveCompare(owner) == .orderedSame })
                    ?? candidates.first else {
                throw CLIError.usage(CLIUsageError(
                    code: "missing_flag", message: "No connected GitHub account to create \(owner)/\(repo) with.",
                    hint: "Pass --account <login>, or pipe a token with --token-stdin."))
            }
            guard let secret = accountToken(account) else { throw noAccountToken(account.login) }
            token = secret
            login = account.login
        }

        if (try? await app.repositories.exists(owner, repo, token)) == true {
            throw CLIError.usage(CLIUsageError(
                code: "repo_exists", message: "\(owner)/\(repo) already exists on GitHub.",
                hint: "Drop --create-repo to add it as it is, or choose another name."))
        }
        let isOrganization = login.caseInsensitiveCompare(owner) != .orderedSame
        let new = ProductSetup.NewRepository(owner: owner, ownerIsOrganization: isOrganization,
                                             name: repo, isPrivate: isPrivate)
        let name = (request.payload["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await ProductSetup.createRepository(new, productName: name.isEmpty ? repo : name,
                                                    token: token, service: app.repositories)
        } catch GitHubAuthService.AuthError.apiError(let code) where code == 403 || code == 404 {
            throw CLIError.auth(message: "GitHub didn't allow creating \(owner)/\(repo) (\(code)).",
                                hint: "Check you can create repositories in '\(owner)'.")
        } catch {
            throw CLIError.remote(message: "Couldn't create \(owner)/\(repo): \(error.localizedDescription)")
        }
        return (token, try await probe(owner: owner, repo: repo, token: token, source: "The new repository", app: app))
    }

    private static func probe(owner: String, repo: String, token: String, source: String,
                              app: AppDependencies) async throws -> GitHubRepo {
        do {
            return try await app.fetchRepo(owner, repo, token)
        } catch GitHubAuthService.AuthError.apiError(let code) where code == 401 {
            throw CLIError.auth(message: "\(source) was rejected by GitHub (401).",
                                hint: "It may be expired or revoked.")
        } catch GitHubAuthService.AuthError.apiError(let code) where code == 403 || code == 404 {
            throw CLIError.auth(message: "\(source) can't see \(owner)/\(repo).",
                                hint: "Check the owner and name, and that the token has access to the repository.")
        } catch {
            throw CLIError.remote(message: "Couldn't reach GitHub to check \(owner)/\(repo): "
                                         + error.localizedDescription)
        }
    }

    private static func noAccountToken(_ login: String) -> CLIError {
        .auth(message: "GitHub account '\(login)' has no token on this Mac.",
              hint: "Unlock the Mac if it's locked, or reconnect the account in Love Letter's Settings.")
    }

    // MARK: - update

    static func updateProduct(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let product = try liveProduct(request, deps: deps, app: app)
        let payload = request.payload

        var token: String?
        if payload["token"]?.isEmpty == false || payload["account"]?.isEmpty == false {
            token = try await resolveToken(request, owner: product.owner, repo: product.repo, app: app).0
        }
        let name = (payload["name"] ?? "").trimmingCharacters(in: .whitespaces)
        await ProductSetup.saveGeneral(product,
                                       displayName: name.isEmpty ? product.displayName : name,
                                       mirrorEmailsToGitHub: payload["mirror"].map { $0 == "on" } ?? product.mirrorEmailsToGitHub,
                                       redactEmailAddresses: payload["redact"].map { $0 == "on" } ?? product.redactEmailAddresses,
                                       token: token, products: app.products, secrets: app.secrets)
        // The sidebar's Color menu.
        if let color = payload["color"] {
            app.products.setColor(color == "none" ? nil : color, forRepo: product.id)
        }
        let result = summary(of: product.id, deps: deps)
        return CLIResponse(id: request.id, ok: true,
                           json: result.map { CLIOutput.encode($0) } ?? CLIOutput.encode(ProductResolver.ref(product)))
    }

    // MARK: - remove

    /// The sidebar's Remove: the product and its GitHub token go; the GitHub data stays.
    static func removeProduct(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let product = try liveProduct(request, deps: deps, app: app)
        await app.products.remove(id: product.id)
        syncRegistries(deps: deps, app: app)
        return CLIResponse(id: request.id, ok: true,
                           json: CLIOutput.encode(["removed": ProductResolver.ref(product)]))
    }

    // MARK: - App Store source

    struct AppStoreSourceResult: Codable, Equatable {
        struct App: Codable, Equatable { let id: String; let name: String?; let bundleId: String? }
        let product: ProductRef
        let app: App
    }

    /// The App Store form's Test then Save: verify the key by listing its apps, pick the app,
    /// store the .p8 and restart the product's coordinator.
    static func configureAppStore(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let product = try liveProduct(request, deps: deps, app: app)
        let model = AppStoreSourceFormModel()
        model.issuerID = (request.payload["issuerID"] ?? "").trimmingCharacters(in: .whitespaces)
        model.keyID = (request.payload["keyID"] ?? "").trimmingCharacters(in: .whitespaces)
        model.pemText = request.payload["pem"] ?? ""

        await model.test(makeClient: app.ascClient)
        if case .failed(let message) = model.phase {
            throw CLIError.auth(message: message, hint: "Check --issuer-id, --key-id and the .p8 file.")
        }

        let apps = model.discoveredApps
        func describe(_ app: ASCApp) -> String { "\(app.name) (\(app.bundleId)) \(app.id)" }
        if let wanted = request.payload["appID"], !wanted.isEmpty {
            if !apps.isEmpty, !apps.contains(where: { $0.id == wanted }) {
                throw CLIError.notFound(code: "app_not_found",
                                        message: "This key can't see an app with id \(wanted).",
                                        candidates: apps.map(describe))
            }
            // A key that lists no apps can still name one — the form's manual App Apple ID.
            model.selectedAppID = nil
            model.manualAppID = wanted
        } else if apps.count != 1 {
            throw CLIError.notFound(
                code: apps.isEmpty ? "app_not_found" : "app_ambiguous",
                message: apps.isEmpty ? "The key is valid but lists no apps."
                                      : "The key can see \(apps.count) apps.",
                hint: "Pass --app-id with the numeric App Store Connect app id.",
                candidates: apps.map(describe))
        }
        guard let appID = model.resolvedAppAppleID() else {
            throw CLIError.usage(CLIUsageError(code: "bad_value", message: "No App Store app selected."))
        }

        await ProductSetup.saveAppStoreSource(productID: product.id, issuerID: model.issuerID,
                                              keyID: model.keyID, pem: model.pemText, appAppleID: appID,
                                              products: app.products, registry: app.appStoreRegistry,
                                              secrets: app.secrets)
        let picked = apps.first { $0.id == appID }
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(AppStoreSourceResult(
            product: ProductResolver.ref(product),
            app: .init(id: appID, name: picked?.name, bundleId: picked?.bundleId))))
    }

    // MARK: - Email source

    struct EmailSourceResult: Codable, Equatable {
        let product: ProductRef
        let address: String
        let service: String
        let tested: Bool
    }

    /// The Email form's Test Connection then Save. The login is tested first, as the wizard
    /// does, so a wrong password never leaves a half-configured inbox behind.
    static func configureEmail(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let product = try liveProduct(request, deps: deps, app: app)
        let payload = request.payload
        guard let preset = SMTPCredentials.Preset(rawValue: payload["preset"] ?? "") else {
            throw CLIError.usage(CLIUsageError(code: "bad_value", message: "Unknown --preset."))
        }

        let existing = product.feedbackInboxAccountID.flatMap { app.mailAccounts.account(id: $0) }
        let model = EmailSourceFormModel(productID: product.id, existingAccountID: existing?.id)
        model.applyPresetDefaults(preset)
        model.username = (payload["address"] ?? "").trimmingCharacters(in: .whitespaces)
        model.password = preset.sanitize(password: payload["password"] ?? "")
        if let host = payload["imapHost"], !host.isEmpty { model.imapHost = host }
        if let port = payload["imapPort"], !port.isEmpty { model.imapPort = port }
        if let host = payload["smtpHost"], !host.isEmpty { model.smtpHost = host }
        if let port = payload["smtpPort"], !port.isEmpty { model.smtpPort = port }
        // The wizard names the sender after the product when no name was typed.
        let senderName = (payload["senderName"] ?? "").trimmingCharacters(in: .whitespaces)
        model.senderName = !senderName.isEmpty ? senderName
            : (existing?.senderName.isEmpty == false ? existing!.senderName : product.displayName)
        guard model.canTest else {
            throw CLIError.usage(CLIUsageError(code: "missing_flag",
                                               message: "An address, a password and an IMAP host are required."))
        }

        let tested = payload["skipTest"] == nil
        if tested { try await app.testInbox(model) }

        await ProductSetup.persistEmailSource(product: product, values: model.effectiveAccountValues(),
                                              password: model.password, existingAccountID: existing?.id,
                                              products: app.products, mailAccounts: app.mailAccounts,
                                              mailRegistry: app.mailRegistry, secrets: app.secrets)
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(EmailSourceResult(
            product: ProductResolver.ref(product), address: model.username,
            service: preset.rawValue, tested: tested)))
    }

    /// The Email form's Remove Email Source.
    static func removeEmail(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let product = try liveProduct(request, deps: deps, app: app)
        guard let accountID = product.feedbackInboxAccountID else {
            throw CLIError.notFound(code: "no_email_source",
                                    message: "\(product.displayName) has no email source.")
        }
        await ProductSetup.removeEmailSource(product: product, accountID: accountID,
                                             products: app.products, mailAccounts: app.mailAccounts,
                                             mailRegistry: app.mailRegistry)
        return CLIResponse(id: request.id, ok: true,
                           json: CLIOutput.encode(["removedEmailSourceFrom": ProductResolver.ref(product)]))
    }

    #if canImport(SwiftMail)
    /// The wizard's Test Connection: a bare IMAP login, logged to Activity, with the error
    /// translated the way the form shows it.
    static func testInboxLogin(_ model: EmailSourceFormModel, activityLog: ActivityLog) async throws {
        let logID = activityLog.start(kind: .testConnection, title: "\(model.imapHost):\(model.imapPort)")
        do {
            try await IMAPClient(host: model.imapHost, port: Int(model.imapPort) ?? 993,
                                 username: model.username, password: model.password).testConnection()
            activityLog.finish(logID, status: .success, detail: "Login OK")
        } catch {
            let message = MailErrorTranslator.describe(error, preset: model.preset)
            activityLog.finish(logID, status: .failure, detail: message)
            throw CLIError.auth(message: "Couldn't sign in to \(model.username): \(message)",
                                hint: "Nothing was saved. Fix the password or host, or pass --skip-test.")
        }
    }
    #endif
}
#endif
