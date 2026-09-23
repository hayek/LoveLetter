#if DEBUG
import XCTest
import SwiftData
@testable import LoveLetter

@MainActor
final class LaunchModeTests: XCTestCase {
    func testTestHostAlwaysWinsOverMockMode() {
        // Even if the developer left mock data on, the test host keeps its own in-memory stack.
        XCTAssertEqual(LoveLetterApp.resolveLaunchMode(isTesting: true), .testing)
    }

    func testMockContainerIsInMemoryAndSeedsIntoTheStores() throws {
        let container = try LoveLetterApp.makeContainer(mode: .mock)
        XCTAssertTrue(container.configurations.allSatisfy(\.isStoredInMemoryOnly),
                      "mock mode must never open the on-disk / CloudKit stores")
        try MockDataSeeder.seed(into: ModelContext(container), now: Date())
        let products = ProductStore(context: ModelContext(container))
        XCTAssertEqual(products.repos.map(\.owner), ["mock-studio", "mock-studio", "mock-studio"])
        let versions = VersionStore(context: ModelContext(container))
        XCTAssertEqual(versions.versions(owner: "mock-studio", repo: "pixel-journal").count, 3)
    }
}
#endif
