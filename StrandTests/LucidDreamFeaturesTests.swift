import XCTest
import StrandAnalytics
@testable import Strand

/// Lucid fork additions: vibration notifications, keep-awake hold, pre-sleep training, morning check-in.
@MainActor
final class LucidDreamFeaturesTests: XCTestCase {
    @MainActor
    private final class HapticSpy: LucidDreamHapticSending {
        var calls = 0
        func sendLucidDreamCue() -> String? { calls += 1; return "test-pattern" }
    }

    @MainActor
    private final class NotifierSpy: LucidDreamNotifying {
        var posts: [(id: String, title: String, body: String, passive: Bool)] = []
        func post(identifier: String, title: String, body: String, passive: Bool) {
            posts.append((identifier, title, body, passive))
        }
    }

    @MainActor
    private final class KeepAwakeSpy: LucidDreamKeepAwake {
        private(set) var isHeld = false
        func setHeld(_ held: Bool) { isHeld = held }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "LucidDreamFeaturesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lucid-feat-\(UUID().uuidString)",
                                                                      isDirectory: true)
    }

    private func connectedLive() -> LiveState {
        let live = LiveState()
        live.connected = true
        live.encryptedBond = true
        return live
    }

    func testNewSettingsDefaultOn() {
        let settings = LucidDreamSettingsStore(defaults: isolatedDefaults())
        XCTAssertTrue(settings.notifyOnCue)
        XCTAssertTrue(settings.keepMacAwake)
        XCTAssertEqual(settings.trainingMinutes, LucidDreamTrainingPlan.defaultMinutes)
    }

    func testTestCuePostsANotificationSayingWhy() {
        let notifier = NotifierSpy()
        let controller = LucidDreamController(settings: LucidDreamSettingsStore(defaults: isolatedDefaults()),
                                              live: connectedLive(), repo: Repository(deviceId: "test"),
                                              haptics: HapticSpy(),
                                              eventLog: LucidDreamEventLog(directory: tempDir()),
                                              notifier: notifier)
        controller.testCue()
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertTrue(notifier.posts[0].body.contains("You pressed Test cue"))
    }

    func testNotificationsRespectTheToggle() {
        let settings = LucidDreamSettingsStore(defaults: isolatedDefaults())
        settings.notifyOnCue = false
        let notifier = NotifierSpy()
        let controller = LucidDreamController(settings: settings, live: connectedLive(),
                                              repo: Repository(deviceId: "test"), haptics: HapticSpy(),
                                              eventLog: LucidDreamEventLog(directory: tempDir()),
                                              notifier: notifier)
        controller.testCue()
        XCTAssertTrue(notifier.posts.isEmpty)
    }

    func testTrainingBuzzesOncePerRoundWithAPromptAndOneReplacingNotice() {
        let haptics = HapticSpy()
        let notifier = NotifierSpy()
        let controller = LucidDreamController(settings: LucidDreamSettingsStore(defaults: isolatedDefaults()),
                                              live: connectedLive(), repo: Repository(deviceId: "test"),
                                              haptics: haptics,
                                              eventLog: LucidDreamEventLog(directory: tempDir()),
                                              notifier: notifier)
        controller.startTraining()
        XCTAssertTrue(controller.trainingActive)
        XCTAssertEqual(haptics.calls, 1, "the first round fires immediately")
        XCTAssertEqual(controller.trainingRound, 1)
        XCTAssertEqual(controller.trainingTotal, LucidDreamTrainingPlan.rounds(minutes: LucidDreamTrainingPlan.defaultMinutes))
        XCTAssertEqual(controller.trainingPrompt, LucidDreamTrainingPlan.prompt(round: 1))
        XCTAssertEqual(notifier.posts.map(\.id), ["lucid-training"])
        controller.stopTraining()
        XCTAssertFalse(controller.trainingActive)
    }

    func testTrainingRefusesWithoutASecureLink() {
        let haptics = HapticSpy()
        let controller = LucidDreamController(settings: LucidDreamSettingsStore(defaults: isolatedDefaults()),
                                              live: LiveState(), repo: Repository(deviceId: "test"),
                                              haptics: haptics,
                                              eventLog: LucidDreamEventLog(directory: tempDir()))
        controller.startTraining()
        XCTAssertFalse(controller.trainingActive)
        XCTAssertEqual(haptics.calls, 0)
    }

    func testDisablingReleasesKeepAwake() async {
        let settings = LucidDreamSettingsStore(defaults: isolatedDefaults())
        settings.enabled = true
        let keepAwake = KeepAwakeSpy()
        keepAwake.setHeld(true)
        let controller = LucidDreamController(settings: settings, live: connectedLive(),
                                              repo: Repository(deviceId: "test"), haptics: HapticSpy(),
                                              eventLog: LucidDreamEventLog(directory: tempDir()),
                                              keepAwake: keepAwake)
        controller.start()
        settings.enabled = false
        // setEnabled is deferred one run-loop turn (see start()).
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(keepAwake.isHeld)
    }

    func testJournalOffersCheckInForAMonitoredNightAndTalliesAnswers() {
        let journal = LucidDreamJournal(directory: tempDir(), defaults: isolatedDefaults())
        journal.touch(sessionID: "a", sleepOnset: 0, monitored: false, now: 100)
        XCTAssertNil(journal.pendingCheckIn(now: 100_000), "a night that never reached monitoring is not asked about")
        journal.touch(sessionID: "a", sleepOnset: 0, monitored: true, now: 200)
        journal.recordCue(sessionID: "a", at: 250)
        XCTAssertNil(journal.pendingCheckIn(now: 300), "not until the night has gone quiet")
        let pending = journal.pendingCheckIn(now: 250 + LucidDreamJournal.checkInDelaySeconds)
        XCTAssertEqual(pending?.cueTimes, [250])

        // A nap must not overwrite the unanswered night.
        journal.touch(sessionID: "nap", sleepOnset: 5_000, monitored: false, now: 5_000)
        XCTAssertEqual(journal.night?.sessionID, "a")

        journal.answer(pending!, lucid: true, wokeFromCue: false, dreamRecalled: true, now: 9_000)
        XCTAssertNil(journal.pendingCheckIn(now: 99_999))
        let tally = LucidJournalTally(journal.entries())
        XCTAssertEqual(tally.nights, 1)
        XCTAssertEqual(tally.cuedNights, 1)
        XCTAssertEqual(tally.lucidCued, 1)
        XCTAssertEqual(tally.wokeFromCue, 0)
    }

    func testUncuedNightRecordsNoWakeAnswer() {
        let journal = LucidDreamJournal(directory: tempDir(), defaults: isolatedDefaults())
        journal.touch(sessionID: "b", sleepOnset: 0, monitored: true, now: 0)
        let night = journal.pendingCheckIn(now: LucidDreamJournal.checkInDelaySeconds)!
        journal.answer(night, lucid: false, wokeFromCue: true, dreamRecalled: false, now: 1)
        XCTAssertNil(journal.entries().first?.wokeFromCue)
        XCTAssertEqual(LucidJournalTally(journal.entries()).uncuedNights, 1)
    }
}
