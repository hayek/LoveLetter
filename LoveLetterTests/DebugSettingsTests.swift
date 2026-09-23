#if DEBUG
import XCTest
@testable import LoveLetter

@MainActor
final class DebugSettingsTests: XCTestCase {
    // Never `.standard`: the test host shares the real app's defaults domain.
    private let suiteName = "DebugSettingsTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_default_isOff() {
        XCTAssertFalse(DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false).useMockData)
    }

    func test_useMockData_persistsUnderDebugKey() {
        DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false).useMockData = true
        XCTAssertTrue(defaults.bool(forKey: "debug.useMockData"))
        XCTAssertTrue(DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false).useMockData)
    }

    func test_readUseMockData_readsTheKey() {
        XCTAssertFalse(DebugSettings.readUseMockData(from: defaults))
        defaults.set(true, forKey: DebugSettings.useMockDataKey)
        XCTAssertTrue(DebugSettings.readUseMockData(from: defaults))
    }

    func test_needsRelaunch_whenPendingDiffersFromActive() {
        let s = DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false)
        XCTAssertFalse(s.needsRelaunch)
        s.useMockData = true
        XCTAssertTrue(s.needsRelaunch)
    }

    func test_togglingBackBeforeRelaunch_clearsNeedsRelaunch() {
        let s = DebugSettings(defaults: defaults, mockDataActiveAtLaunch: false)
        s.useMockData = true
        s.useMockData = false
        XCTAssertFalse(s.needsRelaunch)
    }

    func test_launchedInMockMode_turningOffNeedsRelaunch() {
        defaults.set(true, forKey: DebugSettings.useMockDataKey)
        let s = DebugSettings(defaults: defaults, mockDataActiveAtLaunch: true)
        XCTAssertTrue(s.useMockData)
        XCTAssertFalse(s.needsRelaunch)
        s.useMockData = false
        XCTAssertTrue(s.needsRelaunch)
    }
}
#endif
