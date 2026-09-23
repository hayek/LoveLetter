import XCTest
@testable import LoveLetter

@MainActor
final class AddProductWizardModelTests: XCTestCase {
    private func modelWithRepo(_ sources: Set<AddProductWizardModel.Source>) -> AddProductWizardModel {
        let model = AddProductWizardModel()
        model.sources = sources
        model.owner = "acme"; model.repo = "app-feedback"; model.token = "ghp_x"
        return model
    }

    func testStepsFollowChosenSources() {
        let model = AddProductWizardModel()
        model.sources = [.sdk]
        XCTAssertEqual(model.steps, [.sources, .repository, .sdk, .summary])
        model.sources = [.email]
        XCTAssertEqual(model.steps, [.sources, .repository, .email, .summary])
        model.sources = [.appStore]
        XCTAssertEqual(model.steps, [.sources, .repository, .appStore, .summary])
        model.sources = [.sdk, .appStore, .email]
        XCTAssertEqual(model.steps, [.sources, .repository, .appStore, .email, .sdk, .summary])
    }

    func testCannotLeaveSourcesWithNothingChosen() {
        let model = AddProductWizardModel()
        XCTAssertFalse(model.canContinue)
        model.goForward()
        XCTAssertEqual(model.step, .sources)
        model.sources = [.email]
        model.goForward()
        XCTAssertEqual(model.step, .repository)
    }

    func testRepositoryStepNeedsOwnerRepoTokenAndRejectsDuplicates() {
        let model = AddProductWizardModel()
        model.sources = [.sdk]
        model.goForward()
        XCTAssertFalse(model.canContinue)
        model.owner = "acme"; model.repo = "app"
        XCTAssertFalse(model.canContinue, "token still missing")
        model.token = "ghp_x"
        XCTAssertTrue(model.canContinue)
        model.existingRepoKeys = ["acme/app"]
        XCTAssertTrue(model.isDuplicateRepository)
        XCTAssertFalse(model.canContinue)
    }

    func testSummaryPrefillsNameFromRepoAndBackReturns() {
        let model = modelWithRepo([.sdk])
        model.goForward() // repository
        model.goForward() // sdk
        model.goForward() // summary
        XCTAssertEqual(model.step, .summary)
        XCTAssertEqual(model.name, "app-feedback")
        XCTAssertTrue(model.isLastStep)
        model.goBack()
        XCTAssertEqual(model.step, .sdk)
        XCTAssertFalse(model.movedForward)
    }

    func testSuggestedNamePrefersPickedAppStoreApp() {
        let model = modelWithRepo([.appStore])
        model.appStore.discoveredApps = [ASCApp(id: "42", bundleId: "com.acme.app", name: "Acme")]
        model.appStore.selectedAppID = "42"
        XCTAssertEqual(model.suggestedName, "Acme")
    }

    func testMakeConfigCarriesOnlyChosenSources() {
        let model = modelWithRepo([.email])
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
        let model = modelWithRepo([.sdk])
        XCTAssertTrue(model.makeConfig().redactEmailAddresses)
        model.repoIsPrivate = true
        XCTAssertFalse(model.makeConfig().redactEmailAddresses)
    }
}
