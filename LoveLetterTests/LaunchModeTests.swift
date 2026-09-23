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

    override func tearDown() {
        KeychainService.writesSuppressed = false
        super.tearDown()
    }

    // MARK: Review fixes: mock mode must not reach real secrets or real sources

    func testMockModeSuppressesEveryKeychainWrite() async {
        LoveLetterApp.applySideEffectPolicy(for: .mock)
        XCTAssertTrue(KeychainService.writesSuppressed)
        let before = KeychainService.suppressedWriteCount
        // A real repo typed into Add Product while in mock mode shares the owner/repo token slot.
        let real = ProductConfig(displayName: "Real", owner: "someone", repo: "real-app")
        await KeychainService.save(token: "typed-in-mock-mode", for: real)
        await KeychainService.delete(for: real)
        let savedKey = await KeychainService.saveASCKey("pem", for: UUID())
        await KeychainService.deleteASCKey(for: UUID())
        let savedIMAP = await KeychainService.saveIMAPPassword("pw", for: UUID())
        await KeychainService.deleteGitHubToken(for: UUID())
        XCTAssertFalse(savedKey); XCTAssertFalse(savedIMAP)
        XCTAssertEqual(KeychainService.suppressedWriteCount - before, 6)
    }

    func testLiveAndTestingModesKeepKeychainWrites() {
        LoveLetterApp.applySideEffectPolicy(for: .mock)
        LoveLetterApp.applySideEffectPolicy(for: .live)
        XCTAssertFalse(KeychainService.writesSuppressed)
        LoveLetterApp.applySideEffectPolicy(for: .testing)
        XCTAssertFalse(KeychainService.writesSuppressed)
    }

    func testMockModeGivesTheAppStoreRegistryNothingToPoll() {
        // e.g. the user fills in an App Store source on a mock product while exploring Settings.
        let configured = ProductConfig(displayName: "Pixel Journal", owner: "mock-studio", repo: "pixel-journal",
                                       appStoreIssuerID: "issuer", appStoreKeyID: "key", appStoreAppAppleID: "123")
        XCTAssertEqual(LoveLetterApp.ascConfigs(from: [configured], mode: .live).count, 1)
        XCTAssertTrue(LoveLetterApp.ascConfigs(from: [configured], mode: .mock).isEmpty)
    }

    func testMockModeRunsNoMailSync() {
        XCTAssertFalse(LoveLetterApp.LaunchMode.mock.runsExternalSources)
        XCTAssertTrue(LoveLetterApp.LaunchMode.live.runsExternalSources)
        XCTAssertTrue(LoveLetterApp.LaunchMode.testing.runsExternalSources)
    }
}
#endif
