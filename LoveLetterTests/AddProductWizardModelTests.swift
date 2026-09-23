import XCTest
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

    func testRedactsAddressesUnlessRepoKnownPrivate() {
        let model = modelWithRepo()
        XCTAssertTrue(model.makeConfig().redactEmailAddresses)
        model.repoIsPrivate = true
        XCTAssertFalse(model.makeConfig().redactEmailAddresses)
    }
}
