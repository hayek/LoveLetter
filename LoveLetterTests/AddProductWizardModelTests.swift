import XCTest
import SwiftData
@testable import LoveLetter

@MainActor
final class AddProductWizardModelTests: XCTestCase {
    private func modelWithRepo() -> AddProductWizardModel {
        let model = AddProductWizardModel()
        model.owner = "acme"; model.repo = "app-feedback"; model.token = "ghp_x"
        return model
    }

    func testEverySourceGetsItsOwnStep() {
        XCTAssertEqual(AddProductWizardModel().steps, [.repository, .sdk, .appStore, .email, .summary])
    }

    func testRepositoryStepNeedsOwnerRepoTokenAndRejectsDuplicates() {
        let model = AddProductWizardModel()
        XCTAssertFalse(model.canContinue)
        XCTAssertFalse(model.canSkip, "the repository is required")
        model.skip()
        XCTAssertEqual(model.step, .repository)
        model.owner = "acme"; model.repo = "app"
        XCTAssertFalse(model.canContinue, "token still missing")
        model.token = "ghp_x"
        XCTAssertTrue(model.canContinue)
        model.existingRepoKeys = ["acme/app"]
        XCTAssertTrue(model.isDuplicateRepository)
        XCTAssertFalse(model.canContinue)
    }

    func testContinueSetsUpASourceAndSkipLeavesItOff() {
        let model = modelWithRepo()
        model.goForward()                   // → sdk
        model.goForward()                   // sdk set up → appStore
        XCTAssertEqual(model.step, .appStore)
        XCTAssertFalse(model.canContinue, "App Store needs credentials")
        model.skip()                        // → email
        model.skip()                        // → summary
        XCTAssertEqual(model.step, .summary)
        XCTAssertEqual(model.sources, [.sdk])
        XCTAssertEqual(model.name, "app-feedback")
        XCTAssertTrue(model.isLastStep)
    }

    func testGoingBackAndSkippingTurnsASourceOff() {
        let model = modelWithRepo()
        model.goForward(); model.goForward() // sdk set up, now on appStore
        model.goBack()
        XCTAssertEqual(model.step, .sdk)
        XCTAssertFalse(model.movedForward)
        model.skip()
        XCTAssertEqual(model.sources, [])
    }

    func testSuggestedNamePrefersPickedAppStoreApp() {
        let model = modelWithRepo()
        model.goForward(); model.skip()      // on appStore
        model.appStore.issuerID = "iss"; model.appStore.keyID = "kid"; model.appStore.pemText = "pem"
        model.appStore.discoveredApps = [ASCApp(id: "42", bundleId: "com.acme.app", name: "Acme")]
        model.appStore.selectedAppID = "42"
        model.goForward()                    // App Store set up
        XCTAssertEqual(model.suggestedName, "Acme")
    }

    func testMakeConfigCarriesOnlyChosenSources() {
        let model = modelWithRepo()
        model.goForward(); model.skip(); model.skip() // on email
        model.email.username = "f@acme.com"; model.email.password = "pw"
        model.goForward()                    // email set up
        model.appStore.issuerID = "iss"; model.appStore.keyID = "kid"; model.appStore.manualAppID = "42"
        model.name = "  Acme  "
        model.colorHex = "7b8cff"
        let inbox = UUID()
        let config = model.makeConfig(feedbackInboxAccountID: inbox)
        XCTAssertEqual(config.id, model.productID)
        XCTAssertEqual(config.displayName, "Acme")
        XCTAssertEqual(config.owner, "acme")
        XCTAssertEqual(config.repo, "app-feedback")
        XCTAssertEqual(config.colorHex, "7b8cff")
        XCTAssertEqual(config.feedbackInboxAccountID, inbox)
        XCTAssertNil(config.appStoreAppAppleID, "App Store wasn't chosen")
        XCTAssertNil(config.appStoreIssuerID)
    }

    func testSummaryPrefillFollowsLaterChoicesButKeepsATypedName() {
        let model = modelWithRepo()
        model.goForward(); model.skip(); model.skip(); model.skip() // on summary
        XCTAssertEqual(model.name, "app-feedback")
        model.goBack(); model.goBack()               // back on appStore
        model.appStore.issuerID = "iss"; model.appStore.keyID = "kid"; model.appStore.pemText = "pem"
        model.appStore.discoveredApps = [ASCApp(id: "42", bundleId: "com.acme.app", name: "Acme")]
        model.appStore.selectedAppID = "42"
        model.goForward(); model.skip()              // App Store set up → summary
        XCTAssertEqual(model.name, "Acme", "an untouched prefill tracks the picked app")
        model.name = "Acme Pro"
        model.goBack(); model.goBack(); model.skip(); model.skip() // App Store skipped → summary
        XCTAssertEqual(model.name, "Acme Pro", "a typed name is never overwritten")
    }

    func testEmptyNameFallsBackToSuggestion() {
        let model = modelWithRepo()
        model.goForward(); model.skip(); model.skip(); model.skip() // on summary
        model.name = "  "
        XCTAssertTrue(model.canContinue)
        XCTAssertEqual(model.makeConfig().displayName, "app-feedback")
    }

    func testManualAppleIDOfferedOnlyWhenNoAppsToPick() {
        let model = AddProductWizardModel()
        XCTAssertFalse(model.appStoreNeedsManualAppID)
        model.appStore.phase = .failed("nope")
        XCTAssertTrue(model.appStoreNeedsManualAppID)
        model.appStore.phase = .valid
        XCTAssertTrue(model.appStoreNeedsManualAppID, "a valid key that sees no apps")
        model.appStore.discoveredApps = [ASCApp(id: "42", bundleId: "com.acme.app", name: "Acme")]
        XCTAssertFalse(model.appStoreNeedsManualAppID)
    }

    func testRepoFullNameIsTrimmed() {
        let model = modelWithRepo()
        model.owner = " acme "; model.repo = "app-feedback\n"
        XCTAssertEqual(model.repoFullName, "acme/app-feedback")
        model.existingRepoKeys = ["acme/app-feedback"]
        XCTAssertTrue(model.isDuplicateRepository)
    }

    func testRedactsAddressesUnlessRepoKnownPrivate() {
        let model = modelWithRepo()
        XCTAssertTrue(model.makeConfig().redactEmailAddresses)
        model.repoIsPrivate = true
        XCTAssertFalse(model.makeConfig().redactEmailAddresses)
    }

    // MARK: - create

    /// The wizard saves through `ProductSetup.create`, as `loveletter products add` does:
    /// secrets before the product (the loaders reacting to it must find them), the inbox
    /// account created and linked, and the sender named after the product.
    func testCreateSavesSecretsFirstThenTheProductWithItsInbox() async throws {
        let container = try ModelContainer(
            for: Product.self, Repo.self, MailAccount.self, MailAccountLocalState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = ModelContext(container)
        let products = ProductStore(context: context)
        let mailAccounts = MailAccountStore(context: context)

        let model = modelWithRepo()
        model.token = " ghp_x\n"
        model.goForward(); model.skip()              // repository → sdk skipped → appStore
        model.appStore.issuerID = "iss"; model.appStore.keyID = "kid"; model.appStore.pemText = "PEM"
        model.appStore.discoveredApps = [ASCApp(id: "42", bundleId: "com.acme.app", name: "Acme")]
        model.appStore.selectedAppID = "42"
        model.goForward()                            // → email
        model.email.username = "fb@acme.com"; model.email.password = "pw"
        model.goForward()                            // → summary
        XCTAssertEqual(model.sources, [.appStore, .email])

        let log = SecretLog()
        let productID = model.productID
        let secrets = ProductSecrets(
            saveToken: { token, product in
                let saved = await MainActor.run { products.products.contains { $0.id == product.id } }
                await log.record("token:\(token):\(saved ? "after" : "before")")
            },
            saveASCKey: { pem, id in await log.record("asc:\(pem):\(id == productID)") },
            saveMailPassword: { password, _ in await log.record("mail:\(password)") })

        let product = await model.create(products: products, mailAccounts: mailAccounts,
                                         mailRegistry: nil, secrets: secrets)

        let recorded = await log.entries
        XCTAssertEqual(recorded, ["mail:pw", "asc:PEM:true", "token:ghp_x:before"])
        let saved = try XCTUnwrap(products.products.first { $0.id == productID })
        XCTAssertEqual(saved, product)
        XCTAssertEqual(saved.displayName, "Acme")
        XCTAssertEqual(saved.appStoreAppAppleID, "42")
        let inbox = try XCTUnwrap(saved.feedbackInboxAccountID.flatMap { mailAccounts.account(id: $0) })
        XCTAssertEqual(inbox.imapUsername, "fb@acme.com")
        XCTAssertEqual(inbox.senderName, "Acme", "an unnamed sender takes the product's name")
        XCTAssertEqual(inbox.feedbackProductID, productID)
    }
}

private actor SecretLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

