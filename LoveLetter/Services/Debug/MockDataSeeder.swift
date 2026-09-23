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
