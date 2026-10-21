import XCTest
@testable import StrandAnalytics

final class LucidDreamRemDetectorTests: XCTestCase {
    private let onset = 1_000

    private var config: LucidDreamConfig {
        LucidDreamConfig(enabled: true, monitoringDelaySeconds: 270 * 60,
                         stableREMSeconds: 5 * 60, maxCuesPerEpisode: 2,
                         cueDelaySeconds: 60, stopOnArousal: true)
    }

    private func observation(_ now: Int, stage: String = "light", stageStart: Int? = nil,
                             stageAt: Int? = nil,
                             heartRate: Int? = 62, movement: Double? = 0.02,
                             movementAt: Int? = nil, significantMovement: Bool = false,
                             connected: Bool = true, bonded: Bool = true,
                             session: String? = "sleep-1000") -> LucidDreamObservation {
        LucidDreamObservation(
            now: now, sessionID: session, sleepOnset: session == nil ? nil : onset,
            stage: stage, stageStartedAt: stageStart ?? now, stageObservedAt: stageAt ?? now,
            heartRate: heartRate, movement: movement, movementObservedAt: movementAt ?? now,
            significantMovement: significantMovement, connected: connected,
            encryptedBond: bonded, worn: true)
    }

    private func primedDetector(at now: Int? = nil) -> LucidDreamRemDetector {
        var detector = LucidDreamRemDetector()
        _ = detector.evaluate(observation(now ?? onset + 270 * 60), config: config)
        return detector
    }

    func testFeatureDisabledNeverCues() {
        var detector = LucidDreamRemDetector()
        var off = config
        off.enabled = false
        let now = onset + 300 * 60
        let result = detector.evaluate(observation(now, stage: "rem", stageStart: now - 600), config: off)
        XCTAssertFalse(result.shouldCue)
        XCTAssertEqual(result.state, .disabled)
    }

    func testEarlySleepNeverCues() {
        var detector = LucidDreamRemDetector()
        let now = onset + 269 * 60
        let result = detector.evaluate(observation(now, stage: "rem", stageStart: now - 600), config: config)
        XCTAssertFalse(result.shouldCue)
        XCTAssertEqual(result.state, .earlySleep)
    }

    func testBriefREMDoesNotCue() {
        let start = onset + 275 * 60
        var detector = primedDetector()
        let result = detector.evaluate(observation(start + 4 * 60, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(result.shouldCue)
        XCTAssertEqual(result.state, .possibleREM)
    }

    func testStableREMCuesOnce() {
        let start = onset + 275 * 60
        var detector = primedDetector()
        let result = detector.evaluate(observation(start + 5 * 60, stage: "rem", stageStart: start), config: config)
        XCTAssertTrue(result.shouldCue)
        XCTAssertEqual(result.cueNumber, 1)
        XCTAssertEqual(detector.cueCount, 1)
        XCTAssertEqual(detector.stableREMAt, start + 5 * 60)
    }

    func testMissingRequiredSensorStreamsNeverCue() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var noHeartRate = primedDetector()
        let withoutHeartRate = noHeartRate.evaluate(
            observation(firstAt, stage: "rem", stageStart: start, heartRate: nil),
            config: config)
        XCTAssertFalse(withoutHeartRate.shouldCue)
        XCTAssertEqual(withoutHeartRate.state, .stableREM)

        var noMovement = primedDetector()
        let withoutMovement = noMovement.evaluate(
            observation(firstAt, stage: "rem", stageStart: start, movement: nil),
            config: config)
        XCTAssertFalse(withoutMovement.shouldCue)
        XCTAssertEqual(withoutMovement.state, .stableREM)
    }

    func testStaleOrFutureEvidenceNeverCues() {
        let now = onset + 300 * 60
        var staleStageDetector = primedDetector()
        let staleStage = staleStageDetector.evaluate(
            observation(now, stage: "rem", stageStart: now - 10 * 60,
                        stageAt: now - 20 * 60 - 1), config: config)
        XCTAssertFalse(staleStage.shouldCue)
        XCTAssertEqual(staleStage.state, .monitoring)

        var futureStageDetector = primedDetector()
        let futureStage = futureStageDetector.evaluate(
            observation(now, stage: "rem", stageStart: now - 10 * 60,
                        stageAt: now + 1), config: config)
        XCTAssertFalse(futureStage.shouldCue)
        XCTAssertEqual(futureStage.state, .monitoring)

        var futureMovementDetector = primedDetector()
        let futureMovement = futureMovementDetector.evaluate(
            observation(now, stage: "rem", stageStart: now - 5 * 60,
                        movementAt: now + 1), config: config)
        XCTAssertFalse(futureMovement.shouldCue)
        XCTAssertEqual(futureMovement.state, .stableREM)
    }

    func testUnencryptedConnectionNeverCues() {
        let start = onset + 275 * 60
        var detector = primedDetector()
        let result = detector.evaluate(
            observation(start + 5 * 60, stage: "rem", stageStart: start, bonded: false),
            config: config)
        XCTAssertFalse(result.shouldCue)
        XCTAssertEqual(result.state, .waitingForSleep)
    }

    func testCueLimitIsRespected() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)
        XCTAssertTrue(detector.evaluate(observation(firstAt + 60, stage: "rem", stageStart: start), config: config).shouldCue)
        let third = detector.evaluate(observation(firstAt + 120, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(third.shouldCue)
        XCTAssertEqual(detector.cueCount, 2)
    }

    func testCueIntervalIsRespected() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)
        let tooSoon = detector.evaluate(observation(firstAt + 59, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(tooSoon.shouldCue)
        XCTAssertEqual(tooSoon.state, .cooldown)
        XCTAssertTrue(detector.evaluate(observation(firstAt + 60, stage: "rem", stageStart: start), config: config).shouldCue)
    }

    func testArousalStopsFurtherCuesForEpisode() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)
        let aroused = detector.evaluate(
            observation(firstAt + 60, stage: "rem", stageStart: start, significantMovement: true),
            config: config)
        XCTAssertFalse(aroused.shouldCue)
        XCTAssertTrue(aroused.probableArousal)
        XCTAssertFalse(detector.evaluate(
            observation(firstAt + 180, stage: "rem", stageStart: start), config: config).shouldCue)
    }

    func testPostCueHeartRateRiseStopsFurtherCues() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(
            observation(firstAt, stage: "rem", stageStart: start, heartRate: 62),
            config: config).shouldCue)

        let aroused = detector.evaluate(
            observation(firstAt + 60, stage: "rem", stageStart: start, heartRate: 80),
            config: config)
        XCTAssertFalse(aroused.shouldCue)
        XCTAssertTrue(aroused.probableArousal)
        XCTAssertEqual(aroused.stopReason, "heart-rate rise")
    }

    func testMovementBeforeFirstCueSuppressesSameEpisode() {
        let start = onset + 275 * 60
        let firstEligibleAt = start + 5 * 60
        var detector = primedDetector()
        let movement = detector.evaluate(
            observation(firstEligibleAt, stage: "rem", stageStart: start,
                        significantMovement: true), config: config)
        XCTAssertTrue(movement.probableArousal)

        let sameEpisode = detector.evaluate(
            observation(firstEligibleAt + 60, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(sameEpisode.shouldCue)
        XCTAssertEqual(sameEpisode.state, .aroused)
    }

    func testNewREMEpisodeResetsCueCounterAfterRealGap() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)
        XCTAssertTrue(detector.evaluate(observation(firstAt + 60, stage: "rem", stageStart: start), config: config).shouldCue)
        _ = detector.evaluate(observation(firstAt + 240, stage: "light", stageStart: firstAt + 60), config: config)
        XCTAssertEqual(detector.cueCount, 0)
        let nextStart = firstAt + 300
        let next = detector.evaluate(
            observation(nextStart + 300, stage: "rem", stageStart: nextStart), config: config)
        XCTAssertTrue(next.shouldCue)
        XCTAssertEqual(next.cueNumber, 1)
    }

    func testDirectWakeToREMAfterRealGapStartsNewEpisode() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(
            observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)

        let wakeStart = firstAt + 30
        _ = detector.evaluate(
            observation(wakeStart + 30, stage: "wake", stageStart: wakeStart), config: config)
        let nextREMStart = wakeStart + 3 * 60
        let next = detector.evaluate(
            observation(nextREMStart + 5 * 60, stage: "rem", stageStart: nextREMStart),
            config: config)
        XCTAssertTrue(next.shouldCue)
        XCTAssertEqual(next.cueNumber, 1)
    }

    func testDisconnectAndReconnectCannotCreateCueLoop() {
        let start = onset + 275 * 60
        var detector = primedDetector()
        let disconnected = detector.evaluate(
            observation(start + 300, stage: "rem", stageStart: start, connected: false), config: config)
        XCTAssertFalse(disconnected.shouldCue)
        let reconnected = detector.evaluate(
            observation(start + 301, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(reconnected.shouldCue)
        XCTAssertEqual(reconnected.state, .possibleREM)
    }

    func testDisconnectAfterCueSuppressesRestOfSameEpisode() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(
            observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)

        let disconnected = detector.evaluate(
            observation(firstAt + 30, stage: "rem", stageStart: start, connected: false),
            config: config)
        XCTAssertFalse(disconnected.shouldCue)

        let reconnected = detector.evaluate(
            observation(firstAt + 31, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(reconnected.shouldCue)
        XCTAssertEqual(detector.cueCount, 1)

        let sameEpisode = detector.evaluate(
            observation(firstAt + 10 * 60, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(sameEpisode.shouldCue)
        XCTAssertEqual(sameEpisode.state, .cueSent)
    }

    func testMissingSessionAfterCueDoesNotResetEpisodeGuard() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(
            observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)

        let missing = detector.evaluate(
            observation(firstAt + 30, session: nil), config: config)
        XCTAssertFalse(missing.shouldCue)

        let restored = detector.evaluate(
            observation(firstAt + 10 * 60, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(restored.shouldCue)
        XCTAssertEqual(detector.cueCount, 1)
        XCTAssertEqual(restored.state, .cueSent)
    }

    func testRejectedHapticSuppressesRestOfEpisode() {
        let start = onset + 275 * 60
        let firstAt = start + 5 * 60
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(
            observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)
        detector.suppressCurrentEpisode()

        let later = detector.evaluate(
            observation(firstAt + 10 * 60, stage: "rem", stageStart: start), config: config)
        XCTAssertFalse(later.shouldCue)
        XCTAssertEqual(later.state, .aroused)
    }

    func testApplicationRestartCannotCueImmediately() {
        let now = onset + 300 * 60
        var restarted = LucidDreamRemDetector()
        let result = restarted.evaluate(
            observation(now, stage: "rem", stageStart: now - 15 * 60), config: config)
        XCTAssertFalse(result.shouldCue)
        XCTAssertEqual(result.state, .possibleREM)
    }

    func testSecondCueRequiresFreshPostCueMovement() {
        let start = onset + 275 * 60
        let firstAt = start + 300
        var detector = primedDetector()
        XCTAssertTrue(detector.evaluate(observation(firstAt, stage: "rem", stageStart: start), config: config).shouldCue)
        let stale = detector.evaluate(
            observation(firstAt + 60, stage: "rem", stageStart: start, movementAt: firstAt), config: config)
        XCTAssertFalse(stale.shouldCue)
        XCTAssertEqual(stale.state, .observingResponse)
    }
}
