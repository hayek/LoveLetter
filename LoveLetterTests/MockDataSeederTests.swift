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
                             SentReleaseNotification.self, RepoFetchState.self, ReplyTemplate.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
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

    func testEveryProductHasReplyTemplates() throws {
        let context = try makeSeededContext()
        let templates = try context.fetch(FetchDescriptor<ReplyTemplate>())
        for product in try products(context) {
            let own = templates.filter { $0.repoOwner == product.owner && $0.repoName == product.repo }
            XCTAssertEqual(own.count, MockDataSeeder.replyTemplates.count, product.displayName)
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
