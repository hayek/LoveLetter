#if os(macOS)
import Foundation
import SwiftData

/// What `versions release` needs from the release mailer — `ReleaseNotificationService` in the
/// app, a recorder in tests.
@MainActor
protocol ReleaseMailing {
    func send(repo: ProductConfig, version: ProjectVersion, recipients: [ReleaseRecipient],
              feedback: [FeedbackIssue], template: ReleaseEmailTemplate, appName: String,
              onProgress: @escaping (Int, Int) -> Void) async
}

#if canImport(SwiftMail)
extension ReleaseNotificationService: ReleaseMailing {}
#endif

/// `versions create|update|delete|release` — the app side. Each one drives `VersionService`
/// exactly as the inspector's version sheets do.
extension CLIRequestHandlers {

    static func versionService(_ deps: Dependencies, app: AppDependencies) -> VersionService {
        VersionService(store: app.versions, client: app.milestoneClient, tokenLoader: deps.tokenProvider)
    }

    /// The version object the app's `VersionStore` owns. Edits must go to that instance: the
    /// service saves through the store's context, so a copy fetched elsewhere would never persist.
    static func storedVersion(_ request: CLIRequest, config: ProductConfig,
                              app: AppDependencies) throws -> ProjectVersion {
        try VersionQuery.find(request.payload["version"] ?? "",
                              in: app.versions.versions(owner: config.owner, repo: config.repo),
                              config: config)
    }

    /// Service and validator failures, as CLI errors with the right exit code.
    static func versionError(_ error: Error, config: ProductConfig) -> CLIError {
        switch error {
        case let error as CLIError:
            return error
        case VersionService.ServiceError.noToken:
            return noToken(config)
        case let error as VersionService.ServiceError:
            return .usage(CLIUsageError(code: "bad_value", message: error.localizedDescription))
        case let error as VersionNameValidator.Failure:
            return .usage(CLIUsageError(code: "bad_value", message: error.localizedDescription))
        default:
            return .remote(message: error.localizedDescription)
        }
    }

    static func versionResponse(_ request: CLIRequest, version: ProjectVersion, config: ProductConfig,
                                deps: Dependencies, warnings: [String] = []) -> CLIResponse {
        let tasks = VersionQuery.issues(config: config, local: deps.local).tasks
        return CLIResponse(id: request.id, ok: true, warnings: warnings,
                           json: CLIOutput.encode(VersionQuery.item(version, tasks: tasks)))
    }

    // MARK: - create

    /// `NewVersionSheet` → `RootView.createVersion`: the local version, then its GitHub
    /// milestone. A failed milestone is rolled back — the app's Dismiss on a failed card — so
    /// the command can simply be re-run.
    static func createVersion(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let config = try resolveConfig(request, cloud: deps.cloud)
        let version: ProjectVersion
        do {
            version = try app.versions.create(repoOwner: config.owner, repoName: config.repo,
                                              name: request.payload["version"] ?? "",
                                              releaseTitle: request.payload["title"] ?? "",
                                              changelog: request.payload["changelog"] ?? "")
        } catch {
            throw versionError(error, config: config)
        }
        do {
            try await versionService(deps, app: app).provisionMilestone(repo: config, version: version)
        } catch {
            app.versions.delete(version)
            throw versionError(error, config: config)
        }
        return versionResponse(request, version: version, config: config, deps: deps)
    }

    // MARK: - update

    /// `VersionDetailView`'s Apply: title and changelog first, then any rename — which PATCHes
    /// the milestone and cascades the new name through the cache and saved filters.
    static func updateVersion(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let config = try resolveConfig(request, cloud: deps.cloud)
        let version = try storedVersion(request, config: config, app: app)
        let payload = request.payload
        let service = versionService(deps, app: app)

        let title = payload["setTitle"] != nil ? (payload["title"] ?? "") : version.releaseTitle
        let changelog = payload["setChangelog"] != nil ? (payload["changelog"] ?? "") : version.changelog
        let newName = (payload["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if title != version.releaseTitle || changelog != version.changelog {
                try await service.updateDetails(repo: config, version: version, title: title, changelog: changelog)
            }
            if !newName.isEmpty, newName != version.name {
                let cascade = VersionRenameCascade(cacheContext: app.cacheContext, filterStore: app.filterStore)
                try await service.rename(repo: config, version: version, to: newName, cascade: cascade)
                // The windows' task lists are re-read from the renamed cache.
                await deps.registry.load(productID: config.id)
            }
        } catch {
            throw versionError(error, config: config)
        }
        return versionResponse(request, version: version, config: config, deps: deps)
    }

    // MARK: - delete

    /// `VersionDetailView`'s Delete Version: the milestone on GitHub, then the local record.
    static func deleteVersion(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let config = try resolveConfig(request, cloud: deps.cloud)
        let version = try storedVersion(request, config: config, app: app)
        let name = version.name
        do {
            try await versionService(deps, app: app).deleteVersion(repo: config, version: version)
        } catch {
            throw versionError(error, config: config)
        }
        return CLIResponse(id: request.id, ok: true, json: CLIOutput.encode(["deleted": name]))
    }

    // MARK: - release

    struct ReleaseResult: Codable, Equatable {
        let version: VersionItem
        let emailed: [String]
        let failed: [String]
        /// A GitHub Release was published (false for a milestone-only release).
        let githubRelease: Bool
        let tag: String?
    }

    /// The Release sheet's Send & Release — email each chosen recipient, then close the
    /// milestone and publish the release. With no mail account it is the detail view's
    /// "Mark released (no email)" instead: the milestone closes and no GitHub release is published.
    static func releaseVersion(_ request: CLIRequest, deps: Dependencies) async throws -> CLIResponse {
        let app = try requireApp(deps)
        let config = try resolveConfig(request, cloud: deps.cloud)
        let version = try storedVersion(request, config: config, app: app)
        guard !version.releasePublished else {
            throw CLIError.usage(CLIUsageError(code: "already_released",
                                               message: "Version \(version.name) is already released."))
        }
        let payload = request.payload
        let issues = VersionQuery.issues(config: config, local: deps.local)
        let chosen = try releaseRecipients(
            ReleaseRecipientCalculator.recipients(versionNamed: version.name,
                                                  tasks: issues.tasks, feedback: issues.feedback),
            alreadySent: app.versions.alreadyNotifiedEmails(for: version),
            only: lines(payload["recipients"]), skip: lines(payload["skip"]),
            resend: payload["resend"] != nil, noEmail: payload["noEmail"] != nil)

        // The Release… button exists only when there's an account to send from; without one
        // the app offers "Mark released (no email)", which closes the milestone only.
        let canEmail = app.mailAccounts.defaultSender != nil
        if !chosen.isEmpty {
            guard canEmail, let makeMailer = app.releaseMailer else {
                throw CLIError.auth(message: "No mail account is set up to send release emails.",
                                    hint: "Add one in Love Letter's Email settings, or pass --no-email.")
            }
            var template = ReleaseEmailTemplate.default(appName: config.displayName, version: version.name,
                                                        whatsNew: version.changelog)
            if let subject = payload["subject"], !subject.isEmpty { template.subject = subject }
            if let body = payload["body"], !body.isEmpty { template.body = body }
            await makeMailer().send(repo: config, version: version, recipients: chosen,
                                    feedback: issues.feedback, template: template,
                                    appName: config.displayName, onProgress: { _, _ in })
        }
        // Each send is recorded as it goes; read back how this run's went.
        let chosenEmails = Set(chosen.map(\.email))
        let outcomes = Dictionary(app.versions.sentNotifications(for: version)
            .filter { chosenEmails.contains($0.recipientEmail) }
            .map { ($0.recipientEmail, $0.status) }, uniquingKeysWith: { newest, _ in newest })
        let emailed = chosen.map(\.email).filter { outcomes[$0] == .sent }
        let failed = chosen.map(\.email).filter { outcomes[$0] != .sent }

        let tag = version.releaseTag ?? "v\(version.name)"
        let published: Bool
        do {
            published = try await versionService(deps, app: app).release(
                repo: config, version: version, tag: tag, target: nil, publishRelease: canEmail, now: Date())
        } catch {
            let failure = versionError(error, config: config)
            guard emailed.isEmpty else {
                throw CLIError.remote(message: "Emailed \(emailed.count) recipient(s), but releasing failed: "
                                             + failure.message,
                                      hint: "Re-run without --resend to release; those recipients won't be emailed twice.")
            }
            throw failure
        }

        var warnings: [String] = []
        if !failed.isEmpty { warnings.append("\(failed.count) release email(s) failed — see Activity in Love Letter.") }
        if canEmail && !published {
            warnings.append("The target repository has no commit to tag, so this was a milestone-only release.")
        } else if !canEmail {
            // Said out loud: an agent reading only `ok` would report a published release.
            warnings.append("No mail account is set up in Love Letter, so this only closed the milestone "
                            + "(the app's \"Mark released (no email)\"); no GitHub release was published.")
        }
        let tasks = issues.tasks
        return CLIResponse(id: request.id, ok: true, warnings: warnings, json: CLIOutput.encode(ReleaseResult(
            version: VersionQuery.item(version, tasks: tasks),
            emailed: emailed.map(FeedbackQuery.redact), failed: failed.map(FeedbackQuery.redact),
            githubRelease: published, tag: published ? tag : nil)))
    }

    /// The Release sheet's checkboxes: everyone, minus those already emailed (unless resending),
    /// narrowed by `only` and `skip`. Addresses compare case-insensitively.
    static func releaseRecipients(_ recipients: [ReleaseRecipient], alreadySent: Set<String>,
                                  only: [String], skip: [String], resend: Bool,
                                  noEmail: Bool) throws -> [ReleaseRecipient] {
        guard !noEmail else { return [] }
        func key(_ email: String) -> String { email.trimmingCharacters(in: .whitespaces).lowercased() }
        let known = Set(recipients.map { key($0.email) })
        let unknown = (only + skip).filter { !known.contains(key($0)) }
        guard unknown.isEmpty else {
            throw CLIError.notFound(code: "recipient_not_found",
                                    message: "Not a recipient of this release: \(unknown.joined(separator: ", ")).",
                                    hint: "Run `versions recipients --include-emails` to see them.",
                                    candidates: recipients.map { FeedbackQuery.redact($0.email) })
        }
        let onlyKeys = Set(only.map(key)), skipKeys = Set(skip.map(key))
        let sentKeys = Set(alreadySent.map(key))
        return recipients.filter { recipient in
            let email = key(recipient.email)
            if !onlyKeys.isEmpty, !onlyKeys.contains(email) { return false }
            if skipKeys.contains(email) { return false }
            // Naming someone with --recipient is an explicit resend for them.
            if sentKeys.contains(email), !resend, !onlyKeys.contains(email) { return false }
            return true
        }
    }

    private static func lines(_ raw: String?) -> [String] {
        (raw ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
#endif
