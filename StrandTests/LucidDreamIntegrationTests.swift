import XCTest
@testable import Strand

@MainActor
final class LucidDreamIntegrationTests: XCTestCase {
    @MainActor
    private final class HapticSpy: LucidDreamHapticSending {
        var calls = 0
        var result: String? = "test-pattern"

        func sendLucidDreamCue() -> String? {
            calls += 1
            return result
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "LucidDreamIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func isolatedEventLog() -> LucidDreamEventLog {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucid-test-\(UUID().uuidString)", isDirectory: true)
        return LucidDreamEventLog(directory: directory)
    }

    func testSettingsHaveRequestedSafeDefaults() {
        let settings = LucidDreamSettingsStore(defaults: isolatedDefaults())
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.monitoringDelayMinutes, 270)
        XCTAssertEqual(settings.stableREMMinutes, 5)
        XCTAssertEqual(settings.maxCuesPerEpisode, 2)
        XCTAssertEqual(settings.cueDelaySeconds, 60)
        XCTAssertTrue(settings.stopOnArousal)
        XCTAssertTrue(settings.loggingEnabled)
    }

    func testStartingDisabledControllerNeverTouchesHapticInterface() {
        let settings = LucidDreamSettingsStore(defaults: isolatedDefaults())
        let live = LiveState()
        live.connected = true
        live.encryptedBond = true
        let spy = HapticSpy()
        let controller = LucidDreamController(settings: settings, live: live,
                                              repo: Repository(deviceId: "test"),
                                              haptics: spy,
                                              eventLog: isolatedEventLog())
        controller.start()
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(controller.state, .disabled)
    }

    func testManualTestUsesMockedHapticOnlyWhenCalled() {
        let settings = LucidDreamSettingsStore(defaults: isolatedDefaults())
        let spy = HapticSpy()
        let live = LiveState()
        let controller = LucidDreamController(settings: settings, live: live,
                                              repo: Repository(deviceId: "test"),
                                              haptics: spy,
                                              eventLog: isolatedEventLog())
        XCTAssertEqual(spy.calls, 0)
        controller.testCue()
        XCTAssertEqual(spy.calls, 0)
        live.connected = true
        live.encryptedBond = true
        controller.testCue()
        XCTAssertEqual(spy.calls, 1)
    }
}
