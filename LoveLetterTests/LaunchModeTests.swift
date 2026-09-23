#if DEBUG
import XCTest
import SwiftData
import Security
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
        KeychainService.accessSuppressed = false
        super.tearDown()
    }

    // MARK: Review fixes: mock mode must not reach real secrets or real sources

    /// Removes every item the suppression tests address, with suppression off, so a regression
    /// that let a write through can't leave synchronizable iCloud Keychain items behind.
    private func removeKeychainItemsAfterTest(repo: ProductConfig, ids: [UUID]) {
        addTeardownBlock {
            KeychainService.accessSuppressed = false
            await KeychainService.delete(for: repo)
            for id in ids {
                await KeychainService.deleteASCKey(for: id)
                await KeychainService.deleteIMAPPassword(for: id)
                await KeychainService.deleteSMTPPassword(for: id)
                await KeychainService.deleteGitHubToken(for: id)
            }
        }
    }

    func testMockModeSuppressesEveryKeychainWrite() async {
        // A real repo typed into Add Product while in mock mode shares the owner/repo token slot.
        let real = ProductConfig(displayName: "Real", owner: "someone", repo: "real-app")
        let id = UUID()
        removeKeychainItemsAfterTest(repo: real, ids: [id])
        LoveLetterApp.applySideEffectPolicy(for: .mock)
        // Guard: never call the real APIs below unless suppression is on.
        guard KeychainService.accessSuppressed else {
            return XCTFail("mock mode must suppress Keychain access")
        }
        let before = KeychainService.suppressedAccessCount
        await KeychainService.save(token: "typed-in-mock-mode", for: real)
        await KeychainService.delete(for: real)
        let savedKey = await KeychainService.saveASCKey("pem", for: id)
        await KeychainService.deleteASCKey(for: id)
        let savedIMAP = await KeychainService.saveIMAPPassword("pw", for: id)
        await KeychainService.deleteIMAPPassword(for: id)
        let savedGitHub = await KeychainService.saveGitHubToken("gh", for: id)
        await KeychainService.deleteGitHubToken(for: id)
        XCTAssertFalse(savedKey); XCTAssertFalse(savedIMAP); XCTAssertFalse(savedGitHub)
        XCTAssertEqual(KeychainService.suppressedAccessCount - before, 8)
    }

    func testMockModeSuppressesEveryKeychainRead() async {
        // A real repo added in mock mode must not pick up the real iCloud token, or task writes
        // and attachment downloads would reach real GitHub.
        let real = ProductConfig(displayName: "Real", owner: "someone", repo: "real-app")
        let id = UUID()
        removeKeychainItemsAfterTest(repo: real, ids: [id])
        LoveLetterApp.applySideEffectPolicy(for: .mock)
        guard KeychainService.accessSuppressed else {
            return XCTFail("mock mode must suppress Keychain access")
        }
        let before = KeychainService.suppressedAccessCount

        let withStatus = KeychainService.loadWithStatus(for: real)
        XCTAssertNil(withStatus.token)
        XCTAssertEqual(withStatus.status, errSecItemNotFound)
        XCTAssertNil(KeychainService.loadSync(for: real))
        let loaded = await KeychainService.load(for: real)
        XCTAssertNil(loaded)
        let legacySMTP = await KeychainService.loadSMTPPassword()
        XCTAssertNil(legacySMTP)
        let legacyIMAP = KeychainService.loadIMAPPasswordResult()
        XCTAssertNil(legacyIMAP.password)
        XCTAssertEqual(legacyIMAP.status, errSecItemNotFound)
        let smtp = await KeychainService.loadSMTPPassword(for: id)
        XCTAssertNil(smtp)
        let imap = KeychainService.loadIMAPPasswordResult(for: id)
        XCTAssertNil(imap.password)
        XCTAssertEqual(imap.status, errSecItemNotFound)
        let gitHub = await KeychainService.loadGitHubToken(for: id)
        XCTAssertNil(gitHub)
        XCTAssertNil(KeychainService.loadGitHubTokenSync(for: id))
        let ascKey = await KeychainService.loadASCKey(for: id)
        XCTAssertNil(ascKey)
        XCTAssertNil(KeychainService.loadASCKeySync(for: id))
        // Each load is counted, proving it took the suppressed path rather than finding nothing.
        XCTAssertEqual(KeychainService.suppressedAccessCount - before, 11)
    }

    func testLiveAndTestingModesKeepKeychainAccess() {
        LoveLetterApp.applySideEffectPolicy(for: .mock)
        LoveLetterApp.applySideEffectPolicy(for: .live)
        XCTAssertFalse(KeychainService.accessSuppressed)
        LoveLetterApp.applySideEffectPolicy(for: .testing)
        XCTAssertFalse(KeychainService.accessSuppressed)
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
