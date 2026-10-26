import XCTest
@testable import StrandAnalytics

final class LucidDreamPoliciesTests: XCTestCase {

    func testKeepAwakeHoldsThroughTheNightAndDuringAnySleepState() {
        XCTAssertTrue(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true,
                                                           state: .waitingForSleep, localHour: 22))
        XCTAssertTrue(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true,
                                                           state: .waitingForSleep, localHour: 4))
        XCTAssertFalse(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true,
                                                            state: .waitingForSleep, localHour: 14))
        // A daytime nap still holds while its sleep evidence is fresh...
        XCTAssertTrue(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true,
                                                           state: .earlySleep, localHour: 14,
                                                           evidenceAgeSeconds: 5 * 60))
        // ...but a finished morning session (stale evidence, still `.monitoring`) does not keep the Mac
        // awake all day.
        XCTAssertFalse(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true,
                                                            state: .monitoring, localHour: 14,
                                                            evidenceAgeSeconds: 3 * 60 * 60))
        XCTAssertFalse(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true,
                                                            state: .monitoring, localHour: 14))
    }

    func testKeepAwakeNeverHoldsWhenOffOrOptedOut() {
        XCTAssertFalse(LucidDreamKeepAwakePolicy.shouldHold(enabled: false, keepAwake: true,
                                                            state: .monitoring, localHour: 2))
        XCTAssertFalse(LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: false,
                                                            state: .monitoring, localHour: 2))
    }

    func testRefreshOnlyInsideTheWatchWindowAndAtTheInterval() {
        XCTAssertFalse(LucidDreamRefreshPolicy.shouldRequestSync(state: .earlySleep, lastRequestAt: nil, now: 0))
        XCTAssertFalse(LucidDreamRefreshPolicy.shouldRequestSync(state: .waitingForSleep, lastRequestAt: nil, now: 0))
        XCTAssertTrue(LucidDreamRefreshPolicy.shouldRequestSync(state: .monitoring, lastRequestAt: nil, now: 0))
        XCTAssertFalse(LucidDreamRefreshPolicy.shouldRequestSync(state: .possibleREM, lastRequestAt: 1_000,
                                                                 now: 1_000 + 299))
        XCTAssertTrue(LucidDreamRefreshPolicy.shouldRequestSync(state: .possibleREM, lastRequestAt: 1_000,
                                                                now: 1_000 + 300))
    }

    func testNoExtraSyncsDuringTheDayAfterTheNightEnds() {
        XCTAssertFalse(LucidDreamRefreshPolicy.shouldRequestSync(state: .monitoring, lastRequestAt: nil, now: 0,
                                                                 sleepingNow: false))
    }

    func testRefreshIntervalKeepsEvidenceInsideTheStalenessLimit() {
        XCTAssertLessThan(LucidDreamRefreshPolicy.intervalSeconds, LucidDreamConfig().maxEvidenceAgeSeconds)
    }

    func testTrainingRoundsClampAndPromptsCycle() {
        XCTAssertEqual(LucidDreamTrainingPlan.rounds(minutes: 10), 10)
        XCTAssertEqual(LucidDreamTrainingPlan.rounds(minutes: 1), 5)
        XCTAssertEqual(LucidDreamTrainingPlan.rounds(minutes: 99), 20)
        let n = LucidDreamTrainingPlan.prompts.count
        XCTAssertEqual(LucidDreamTrainingPlan.prompt(round: 1), LucidDreamTrainingPlan.prompts[0])
        XCTAssertEqual(LucidDreamTrainingPlan.prompt(round: n + 1), LucidDreamTrainingPlan.prompts[0])
    }

    func testCueExplanationSaysWhy() {
        let body = LucidDreamCueExplanation.body(remSinceClock: "07:00", remMinutes: 6, sinceOnsetMinutes: 405,
                                                 heartRate: 75, cueNumber: 1, cueDelaySeconds: 60)
        XCTAssertTrue(body.contains("REM sleep for 6 min since 07:00"))
        XCTAssertTrue(body.contains("6 h 45 min after you fell asleep"))
        XCTAssertTrue(body.contains("HR 75 bpm"))
        let repeatBody = LucidDreamCueExplanation.body(remSinceClock: nil, remMinutes: nil, sinceOnsetMinutes: nil,
                                                       heartRate: nil, cueNumber: 2, cueDelaySeconds: 60)
        XCTAssertTrue(repeatBody.contains("Repeat cue"))
        XCTAssertEqual(LucidDreamCueExplanation.title(cueNumber: 1, maxCues: 2), "Lucid cue 1 of 2 sent to your band")
    }
}
