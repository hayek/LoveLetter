#if os(macOS)
import Foundation
import SwiftData

/// Versions and their release plan, computed from the cache. Shared by the CLI's read commands
/// (over the read-only store) and the app-side `versions release` handler (over the app's own
/// contexts), so the recipients `versions recipients` shows are exactly the ones a release emails.
enum VersionQuery {

    /// A product's versions, newest first — the order the inspector lists them.
    static func versions(config: ProductConfig, cloud: ModelContext) -> [ProjectVersion] {
        let owner = config.owner, repo = config.repo
        return ((try? cloud.fetch(FetchDescriptor<ProjectVersion>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    /// Exact name match. The name is the version's identity key, so there's no fuzzy matching.
    static func find(_ name: String, in versions: [ProjectVersion],
                     config: ProductConfig) throws -> ProjectVersion {
        guard let match = versions.first(where: { $0.name == name }) else {
            throw CLIError.notFound(code: "version_not_found",
                                    message: "No version '\(name)' in \(config.owner)/\(config.repo).",
                                    hint: "Run `\(CLIBranding.commandName) versions --product <p>` to list them.",
                                    candidates: versions.map(\.name))
        }
        return match
    }

    /// Every cached issue for the product — feedback and tasks alike, as the app's loader holds them.
    static func allIssues(config: ProductConfig, local: ModelContext) -> [FeedbackIssue] {
        let owner = config.owner, repo = config.repo
        return ((try? local.fetch(FetchDescriptor<CachedIssue>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? []).map { $0.toFeedbackIssue() }
    }

    /// Every cached issue for the product, split the way the app's list view splits them.
    static func issues(config: ProductConfig, local: ModelContext) -> (tasks: [TaskItem], feedback: [FeedbackIssue]) {
        let all = allIssues(config: config, local: local)
        return (all.filter(TaskItem.isTask).map { TaskItem(issue: $0) },
                all.filter { !TaskItem.isTask($0) })
    }

    static func item(_ version: ProjectVersion, tasks: [TaskItem]) -> VersionItem {
        let own = tasks.filter { $0.milestoneTitle == version.name }
        let started = own.contains { $0.status == .inProgress || $0.isCompleted }
        return VersionItem(name: version.name,
                           releaseTitle: version.releaseTitle.isEmpty ? nil : version.releaseTitle,
                           state: version.derivedState(anyTaskStarted: started).rawValue,
                           milestoneNumber: version.milestoneNumber,
                           released: version.releasePublished, releasedAt: version.releasedAt,
                           releaseTag: version.releaseTag,
                           taskCount: own.count, doneCount: own.filter(\.isCompleted).count,
                           createdAt: version.createdAt)
    }

    /// The release-email rows that belong to `version` (see `VersionStore.belongs`).
    static func sent(for version: ProjectVersion, cloud: ModelContext) -> [SentReleaseNotification] {
        let owner = version.repoOwner, repo = version.repoName
        return ((try? cloud.fetch(FetchDescriptor<SentReleaseNotification>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo
        }))) ?? [])
            .filter { VersionStore.belongs($0, to: version) }
            .sorted { $0.sentAt > $1.sentAt }
    }

    /// The same set `VersionStore.alreadyNotifiedEmails` returns: successful sends only.
    static func alreadyNotified(_ sent: [SentReleaseNotification]) -> Set<String> {
        Set(sent.filter { $0.status == .sent }.map(\.recipientEmail))
    }

    static func recipientDTOs(_ recipients: [ReleaseRecipient], alreadySent: Set<String>,
                              includeEmails: Bool) -> [ReleaseRecipientDTO] {
        recipients.map {
            ReleaseRecipientDTO(email: includeEmails ? $0.email : FeedbackQuery.redact($0.email),
                                feedback: $0.feedbackNumbers,
                                alreadyEmailed: alreadySent.contains($0.email))
        }
    }

    /// Where the release publishes: the version's override, else the product's connected code
    /// repo, else the feedback repo — the same fallback `VersionService.release` applies.
    static func releaseRepo(_ version: ProjectVersion, config: ProductConfig) -> String {
        let owner = version.connectedRepoOwner ?? config.connectedRepoOwner ?? config.owner
        let name = version.connectedRepoName ?? config.connectedRepoName ?? config.repo
        return "\(owner)/\(name)"
    }

    static func detail(_ version: ProjectVersion, config: ProductConfig, local: ModelContext,
                       cloud: ModelContext, includeEmails: Bool) -> VersionDetailDTO {
        let (tasks, feedback) = issues(config: config, local: local)
        let sent = sent(for: version, cloud: cloud)
        let recipients = ReleaseRecipientCalculator.recipients(versionNamed: version.name,
                                                               tasks: tasks, feedback: feedback)
        let own = tasks.filter { $0.milestoneTitle == version.name }
            .sorted { $0.number > $1.number }
            .map { TaskIndex.dto($0, config: config) }
        return VersionDetailDTO(
            version: item(version, tasks: tasks),
            changelog: version.changelog,
            tasks: own,
            recipients: recipientDTOs(recipients, alreadySent: alreadyNotified(sent),
                                      includeEmails: includeEmails),
            sentEmails: sent.map {
                SentEmailDTO(email: includeEmails ? $0.recipientEmail : FeedbackQuery.redact($0.recipientEmail),
                             feedback: $0.feedbackNumbers, status: $0.status.rawValue,
                             sentAt: $0.sentAt, error: $0.errorDetail)
            },
            releaseRepo: releaseRepo(version, config: config))
    }
}
#endif
