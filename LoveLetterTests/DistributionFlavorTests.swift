import Testing
@testable import LoveLetter

struct DistributionFlavorTests {
    #if os(macOS)
    @Test func directPlistValueEnablesUpdater() {
        let flavor = DistributionFlavor.resolve(infoValue: "direct", hasAppStoreReceipt: false)
        #expect(flavor == .direct)
        #expect(flavor.usesInAppUpdater)
    }

    @Test func appStoreReceiptWinsOverDirectPlistValue() {
        #expect(DistributionFlavor.resolve(infoValue: "direct", hasAppStoreReceipt: true) == .appStore)
    }

    @Test func valueIsCaseInsensitive() {
        #expect(DistributionFlavor.resolve(infoValue: "Direct", hasAppStoreReceipt: false) == .direct)
    }
    #endif

    @Test(arguments: [nil, "", "appstore", "garbage", "$(DISTRIBUTION_FLAVOR)"])
    func missingOrUnknownValueFallsBackToAppStore(_ value: String?) {
        let flavor = DistributionFlavor.resolve(infoValue: value, hasAppStoreReceipt: false)
        #expect(flavor == .appStore)
        #expect(!flavor.usesInAppUpdater)
    }

    @Test func thisTestBuildIsTheAppStoreFlavor() {
        // project.yml defaults DISTRIBUTION_FLAVOR to appstore; only release.sh overrides it.
        #expect(DistributionFlavor.current == .appStore)
    }
}
