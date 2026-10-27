import Foundation
import Combine
import StrandAnalytics
import WhoopStore

@MainActor
protocol LucidDreamHapticSending: AnyObject {
    /// Returns the real pattern identifier when the command was submitted, or nil when unavailable.
    func sendLucidDreamCue() -> String?
}

extension BLEManager: LucidDreamHapticSending {}

/// Bridges NOOP's persisted sleep result to the pure LucidDreamRemDetector and existing haptic API.
/// All automatic cue decisions stay in the detector; this type only gathers evidence and performs effects.
@MainActor
final class LucidDreamController: ObservableObject {
    @Published private(set) var state: LucidDreamState = .disabled
    @Published private(set) var statusText = "Lucid Mode: off"
    @Published private(set) var lastCueAt: Date?
    /// Pre-sleep cue-association practice (`LucidDreamTrainingPlan`).
    @Published private(set) var trainingRound = 0
    @Published private(set) var trainingTotal = 0
    @Published private(set) var trainingPrompt: String?
    var trainingActive: Bool { trainingTimer != nil }
    /// The night awaiting its morning check-in, and the running personal results.
    @Published private(set) var pendingCheckIn: LucidNightRecord?
    @Published private(set) var tally = LucidJournalTally([])
    @Published private(set) var keepAwakeHeld = false

    /// Asks the strap for a fresh history offload; wired by AppModel to `BLEManager.requestLucidDreamSync`.
    var requestSync: (() -> Void)?

    private struct Evidence {
        let sessionID: String
        let sleepOnset: Int
        let stage: String
        let stageStartedAt: Int
        let stageObservedAt: Int
        let movement: Double
        let movementObservedAt: Int
        let significantMovement: Bool
    }

    private let settings: LucidDreamSettingsStore
    private let live: LiveState
    private let repo: Repository
    private let haptics: any LucidDreamHapticSending
    private let eventLog: LucidDreamEventLog
    private var detector = LucidDreamRemDetector()
    private var evidence: Evidence?
    private var cancellables = Set<AnyCancellable>()
    private var activeCancellables = Set<AnyCancellable>()
    private var started = false
    private var previousState: LucidDreamState = .disabled
    private var stageBeforeCue: String?
    private var cueSessionID: String?
    private var lastPostCueEvidenceLoggedAt: Int?
    private let notifier: (any LucidDreamNotifying)?
    private let keepAwake: (any LucidDreamKeepAwake)?
    private let journal: LucidDreamJournal?
    private var lastSyncRequestAt: Int?
    private var lastLoggedArousalReason: String?
    private var trainingTimer: AnyCancellable?
    private var lastTouchAt: Int?
    private var lastTouchMonitored = false

    init(settings: LucidDreamSettingsStore, live: LiveState, repo: Repository,
         haptics: any LucidDreamHapticSending,
         eventLog: LucidDreamEventLog = LucidDreamEventLog(),
         notifier: (any LucidDreamNotifying)? = nil,
         keepAwake: (any LucidDreamKeepAwake)? = nil,
         journal: LucidDreamJournal? = nil) {
        self.settings = settings
        self.live = live
        self.repo = repo
        self.haptics = haptics
        self.eventLog = eventLog
        self.notifier = notifier
        self.keepAwake = keepAwake
        self.journal = journal
        refreshCheckIn(now: Self.now())
    }

    func start() {
        guard !started else { return }
        started = true

        settings.$enabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            // @Published emits from willSet; defer one run-loop turn so the settings object already
            // carries the new value when config and structured log fields are read.
            DispatchQueue.main.async { [weak self] in self?.setEnabled(enabled) }
        }.store(in: &cancellables)

        // Cue-policy changes reset process-local evidence. This is conservative if edited mid-sleep
        // and prevents a shorter threshold from causing an immediate cue. Logging is intentionally
        // excluded because it does not affect cue eligibility.
        for publisher in [
            settings.$monitoringDelayMinutes.removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher(),
            settings.$stableREMMinutes.removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher(),
            settings.$maxCuesPerEpisode.removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher(),
            settings.$cueDelaySeconds.removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher(),
            settings.$stopOnArousal.removeDuplicates().dropFirst()
                .map { _ in () }.eraseToAnyPublisher(),
        ] {
            publisher.sink { [weak self] _ in self?.resetAfterPolicyChange() }
                .store(in: &cancellables)
        }

        settings.$keepMacAwake.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.updateKeepAwake(now: Self.now()) }
        }.store(in: &cancellables)

        if settings.enabled {
            state = .waitingForSleep
            previousState = .waitingForSleep
            statusText = "Lucid Mode: waiting for fresh sleep data"
            activate()
        }
    }

    /// Called after NOOP's existing analytics pass has refreshed computed sleep sessions.
    func refreshEvidence(now requestedNow: Int? = nil) async {
        guard settings.enabled else { return }
        let now = requestedNow ?? Self.now()
        guard let snapshot = await repo.latestLucidDreamSleepSnapshot(since: now - 18 * 60 * 60,
                                                                      now: now),
              let stagesJSON = snapshot.session.stagesJSON,
              let data = stagesJSON.data(using: .utf8),
              let segments = try? JSONDecoder().decode([StageSegment].self, from: data),
              let latest = segments.filter({ $0.end <= min(snapshot.session.endTs, now)
                                             && $0.end > $0.start })
                .max(by: { $0.end < $1.end }),
              let movement = Self.movementSummary(snapshot.motion) else {
            evidence = nil
            evaluate(now: now)
            return
        }

        let movementObservedAt = min(snapshot.session.endTs,
                                    snapshot.session.effectiveStartTs + snapshot.motion.count * Int(SleepStager.epochS))
        let sessionID = "\(snapshot.session.startTs)"
        if let cueSessionID, cueSessionID != sessionID {
            stageBeforeCue = nil
            self.cueSessionID = nil
            lastPostCueEvidenceLoggedAt = nil
        }
        evidence = Evidence(
            sessionID: sessionID,
            sleepOnset: snapshot.session.effectiveStartTs,
            stage: latest.stage,
            stageStartedAt: latest.start,
            stageObservedAt: latest.end,
            movement: movement.value,
            movementObservedAt: movementObservedAt,
            significantMovement: movement.significant)
        evaluate(now: now)
    }

    /// Direct-user-action-only haptic test. This bypasses sleep state but uses the exact automatic cue.
    func testCue() {
        let now = Self.now()
        guard live.connected, live.encryptedBond else {
            statusText = "Test cue unavailable: connect and securely pair your WHOOP"
            record(event: "manual_test_failed", now: now,
                   stopReason: "secure haptic channel unavailable",
                   hapticError: "command not submitted")
            return
        }
        guard let pattern = haptics.sendLucidDreamCue() else {
            statusText = "Test cue unavailable: connect and securely pair your WHOOP"
            record(event: "manual_test_failed", now: now,
                   stopReason: "secure haptic channel unavailable",
                   hapticError: "command not submitted")
            return
        }
        statusText = "Test cue sent"
        record(event: "manual_test_sent", now: now, vibrationTimestamp: now,
               selectedHapticPattern: pattern)
        notify(identifier: "lucid-test-cue", title: "Lucid test cue sent to your band",
               body: "You pressed Test cue in Settings. This is the same subtle buzz used during REM sleep.",
               passive: false)
    }

    var logFileURL: URL { eventLog.fileURL }

    private func evaluate(now: Int) {
        guard settings.enabled else { return }
        let observation = LucidDreamObservation(
            now: now,
            sessionID: evidence?.sessionID,
            sleepOnset: evidence?.sleepOnset,
            stage: evidence?.stage,
            stageStartedAt: evidence?.stageStartedAt,
            stageObservedAt: evidence?.stageObservedAt,
            heartRate: currentHeartRate,
            movement: evidence?.movement,
            movementObservedAt: evidence?.movementObservedAt,
            significantMovement: evidence?.significantMovement ?? false,
            connected: live.connected,
            encryptedBond: live.encryptedBond,
            worn: live.worn)

        let result = detector.evaluate(observation, config: settings.detectorConfig)
        state = result.state
        statusText = result.status

        let oldState = previousState
        let changed = result.state != oldState
        previousState = result.state
        // A probable arousal holds for minutes and is re-evaluated on every HR tick; log it once per
        // reason rather than per tick (6,886 identical lines over two real nights).
        let arousalIsNew = result.probableArousal && result.stopReason != lastLoggedArousalReason
        lastLoggedArousalReason = result.probableArousal ? result.stopReason : nil
        if changed || arousalIsNew {
            let wasInREM = [.possibleREM, .stableREM, .cueSent, .observingResponse,
                            .cooldown, .aroused].contains(oldState)
            let remEnded = result.state == .monitoring && wasInREM
            let event = result.probableArousal ? "probable_arousal"
                : remEnded ? "rem_episode_ended" : "state_changed"
            record(event: event, now: now, probableArousal: result.probableArousal,
                   stopReason: result.stopReason,
                   remEpisodeEnd: remEnded ? now : nil)
        }

        if let cueAt = detector.lastCueAt,
           lastPostCueEvidenceLoggedAt != cueAt,
           (evidence?.stageObservedAt ?? 0) > cueAt
            || (evidence?.movementObservedAt ?? 0) > cueAt {
            record(event: "post_cue_observation", now: now)
            lastPostCueEvidenceLoggedAt = cueAt
        }

        applySideEffects(now: now)

        guard result.shouldCue, let cueNumber = result.cueNumber else { return }
        guard let pattern = haptics.sendLucidDreamCue() else {
            detector.suppressCurrentEpisode()
            state = .aroused
            statusText = "Cue suppressed: haptic command unavailable"
            previousState = .aroused
            record(event: "haptic_failed", now: now, cueNumber: cueNumber,
                   probableArousal: false, stopReason: "haptic command unavailable",
                   hapticError: "command not submitted")
            return
        }

        lastCueAt = Date(timeIntervalSince1970: TimeInterval(now))
        stageBeforeCue = evidence?.stage
        cueSessionID = evidence?.sessionID
        statusText = "Cue \(cueNumber) sent"
        live.append(log: "Lucid Mode: cue \(cueNumber) sent (\(pattern))")
        record(event: "cue_sent", now: now, vibrationTimestamp: now,
               cueNumber: cueNumber, selectedHapticPattern: pattern,
               stopReason: cueNumber >= settings.maxCuesPerEpisode ? "maximum cues reached" : nil)
        if let sessionID = evidence?.sessionID { journal?.recordCue(sessionID: sessionID, at: now) }
        notifyCue(cueNumber: cueNumber, now: now)
    }

    // MARK: - Side effects (keep-awake, fresh syncs, night record)

    private func applySideEffects(now: Int) {
        updateKeepAwake(now: now)
        if LucidDreamRefreshPolicy.shouldRequestSync(state: state, lastRequestAt: lastSyncRequestAt, now: now,
                                                     sleepingNow: sleepingNow(now: now)),
           live.connected, let requestSync {
            lastSyncRequestAt = now
            requestSync()
        }
        let monitored = LucidDreamRefreshPolicy.watchStates.contains(state)
        if let evidence, let journal,
           monitored != lastTouchMonitored || lastTouchAt.map({ now - $0 >= 60 }) ?? true {
            lastTouchAt = now
            lastTouchMonitored = monitored
            // "Seen" is when the newest stage evidence was observed, not the clock: a finished session's
            // stale evidence lingers all day and would otherwise hold the check-in back indefinitely.
            journal.touch(sessionID: evidence.sessionID, sleepOnset: evidence.sleepOnset,
                          monitored: monitored, now: evidence.stageObservedAt)
        }
    }

    private func localHour(_ now: Int) -> Int {
        Calendar.current.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(now)))
    }

    /// Night window or fresh stage evidence: the shared "is this person plausibly asleep now" gate.
    private func sleepingNow(now: Int) -> Bool {
        LucidDreamKeepAwakePolicy.shouldHold(enabled: true, keepAwake: true, state: state,
                                             localHour: localHour(now),
                                             evidenceAgeSeconds: evidence.map { now - $0.stageObservedAt })
    }

    private func updateKeepAwake(now: Int) {
        guard let keepAwake else { return }
        keepAwake.setHeld(settings.enabled && settings.keepMacAwake && sleepingNow(now: now))
        if keepAwakeHeld != keepAwake.isHeld { keepAwakeHeld = keepAwake.isHeld }
    }

    // MARK: - Notifications

    private func notify(identifier: String, title: String, body: String, passive: Bool) {
        guard settings.notifyOnCue, let notifier else { return }
        notifier.post(identifier: identifier, title: title, body: body, passive: passive)
    }

    private func notifyCue(cueNumber: Int, now: Int) {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        let remStart = detector.suspectedREMAt
        let body = LucidDreamCueExplanation.body(
            remSinceClock: remStart.map { clock.string(from: Date(timeIntervalSince1970: TimeInterval($0))) },
            remMinutes: remStart.map { max(0, now - $0) / 60 },
            sinceOnsetMinutes: evidence.map { max(0, now - $0.sleepOnset) / 60 },
            heartRate: detector.heartRateBeforeCue,
            cueNumber: cueNumber,
            cueDelaySeconds: settings.cueDelaySeconds)
        // Overnight: passive (silent, no banner) so the notice cannot wake you; it is waiting in
        // Notification Center in the morning. One id per cue so the night's history is kept.
        notify(identifier: "lucid-cue-\(now)",
               title: LucidDreamCueExplanation.title(cueNumber: cueNumber, maxCues: settings.maxCuesPerEpisode),
               body: body, passive: true)
    }

    // MARK: - Pre-sleep training

    /// Start the cue-association practice: one cue per round, each paired with a lucidity prompt.
    func startTraining() {
        guard trainingTimer == nil else { return }
        guard live.connected, live.encryptedBond else {
            statusText = "Training unavailable: connect and securely pair your WHOOP"
            return
        }
        trainingTotal = LucidDreamTrainingPlan.rounds(minutes: settings.trainingMinutes)
        trainingRound = 0
        record(event: "training_started", now: Self.now())
        trainingTimer = Timer.publish(every: TimeInterval(LucidDreamTrainingPlan.roundSeconds),
                                      on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.trainingTick() }
        trainingTick()
    }

    func stopTraining(completed: Bool = false) {
        guard trainingTimer != nil else { return }
        trainingTimer = nil
        trainingPrompt = completed ? LucidDreamTrainingPlan.closingPrompt : nil
        record(event: completed ? "training_completed" : "training_stopped", now: Self.now())
        objectWillChange.send()
    }

    private func trainingTick() {
        guard trainingRound < trainingTotal else { stopTraining(completed: true); return }
        let now = Self.now()
        guard live.connected, live.encryptedBond, let pattern = haptics.sendLucidDreamCue() else {
            statusText = "Training paused: strap link unavailable"
            stopTraining()
            return
        }
        trainingRound += 1
        trainingPrompt = LucidDreamTrainingPlan.prompt(round: trainingRound)
        record(event: "training_cue_sent", now: now, vibrationTimestamp: now,
               cueNumber: trainingRound, selectedHapticPattern: pattern)
        // One replacing notice for the whole session rather than one per round.
        notify(identifier: "lucid-training",
               title: "Lucid training cue \(trainingRound) of \(trainingTotal) sent to your band",
               body: "Pre-sleep practice: \(trainingPrompt ?? "")", passive: false)
    }

    // MARK: - Morning check-in

    func refreshCheckIn(now: Int) {
        guard let journal else { return }
        let pending = journal.pendingCheckIn(now: now)
        if pending != pendingCheckIn { pendingCheckIn = pending }
        let newTally = LucidJournalTally(journal.entries())
        if newTally != tally { tally = newTally }
    }

    func submitCheckIn(lucid: Bool, wokeFromCue: Bool?, dreamRecalled: Bool) {
        guard let journal, let night = pendingCheckIn else { return }
        let now = Self.now()
        journal.answer(night, lucid: lucid, wokeFromCue: wokeFromCue, dreamRecalled: dreamRecalled, now: now)
        record(event: "check_in", now: now, cueNumber: night.cueTimes.count,
               stopReason: "lucid=\(lucid) woke=\(wokeFromCue.map(String.init(describing:)) ?? "n/a") recalled=\(dreamRecalled)")
        refreshCheckIn(now: now)
    }

    private func record(event: String, now: Int, vibrationTimestamp: Int? = nil,
                        cueNumber: Int? = nil, selectedHapticPattern: String? = nil,
                        probableArousal: Bool = false, stopReason: String? = nil,
                        remEpisodeEnd: Int? = nil, hapticError: String? = nil) {
        guard settings.loggingEnabled else { return }
        let monitoringStart = evidence.map { $0.sleepOnset + settings.monitoringDelayMinutes * 60 }
        let cueAt = detector.lastCueAt
        let hasPostCueStage = cueAt.map { (evidence?.stageObservedAt ?? 0) > $0 } ?? false
        let hasPostCueMovement = cueAt.map { (evidence?.movementObservedAt ?? 0) > $0 } ?? false
        eventLog.append(LucidDreamLogEntry(
            timestamp: now,
            event: event,
            sleepSessionID: evidence?.sessionID,
            enabled: settings.enabled,
            sleepOnset: evidence?.sleepOnset,
            monitoringStart: monitoringStart,
            suspectedREMOnset: detector.suspectedREMAt,
            stableREMTime: detector.stableREMAt,
            supportingState: state.rawValue,
            vibrationTimestamp: vibrationTimestamp,
            cueNumber: cueNumber,
            selectedHapticPattern: selectedHapticPattern,
            heartRateBeforeCue: detector.heartRateBeforeCue,
            heartRateAfterCue: cueAt.map { now > $0 ? currentHeartRate : nil } ?? nil,
            movementBeforeCue: detector.movementBeforeCue,
            movementAfterCue: hasPostCueMovement ? evidence?.movement : nil,
            sleepStageBeforeCue: stageBeforeCue,
            sleepStageAfterCue: hasPostCueStage ? evidence?.stage : nil,
            probableArousal: probableArousal,
            stopReason: stopReason,
            remEpisodeEnd: remEpisodeEnd,
            hapticError: hapticError))
        if event == "state_changed" || event == "probable_arousal" {
            live.append(log: statusText)
        } else if event == "rem_episode_ended" {
            live.append(log: "Lucid Mode: REM episode ended")
        } else if event == "post_cue_observation" {
            let movement = evidence?.significantMovement == true ? "significant" : "low"
            live.append(log: "Lucid Mode: post-cue movement \(movement)")
        }
    }

    private static func movementSummary(_ epochs: [Double]) -> (value: Double, significant: Bool)? {
        let finite = epochs.filter { $0.isFinite && $0 >= 0 }
        guard finite.count >= 2 else { return nil }
        let recent = Array(finite.suffix(4))
        let current = recent.reduce(0, +) / Double(recent.count)
        let baselinePool = finite.dropLast(min(4, finite.count)).suffix(120).sorted()
        let baseline = baselinePool.isEmpty ? 0 : baselinePool[baselinePool.count / 2]
        // This only suppresses cues; a conservative false positive cannot cause a vibration.
        let significant = current > max(0.15, baseline * 4)
        return (current, significant)
    }

    private static func now() -> Int { Int(Date().timeIntervalSince1970) }

    private var currentHeartRate: Int? {
        live.heartRate ?? live.rr.last.flatMap {
            $0 > 0 ? Int((60_000.0 / Double($0)).rounded()) : nil
        }
    }

    private func setEnabled(_ enabled: Bool) {
        detector.reset()
        evidence = nil
        stageBeforeCue = nil
        cueSessionID = nil
        lastPostCueEvidenceLoggedAt = nil
        state = enabled ? .waitingForSleep : .disabled
        statusText = enabled ? "Lucid Mode: waiting for fresh sleep data" : "Lucid Mode: off"
        previousState = state
        if enabled { activate() } else { deactivate(); stopTraining() }
        updateKeepAwake(now: Self.now())
        record(event: enabled ? "enabled" : "disabled", now: Self.now())
    }

    private func resetAfterPolicyChange() {
        guard settings.enabled else { return }
        detector.reset()
        evidence = nil
        stageBeforeCue = nil
        cueSessionID = nil
        lastPostCueEvidenceLoggedAt = nil
        state = .waitingForSleep
        previousState = .waitingForSleep
        statusText = "Lucid Mode: settings changed; reacquiring sleep evidence"
        Task { [weak self] in await self?.refreshEvidence() }
    }

    private func activate() {
        guard activeCancellables.isEmpty else { return }
        for publisher in [live.$connected.map { _ in () }.eraseToAnyPublisher(),
                          live.$encryptedBond.map { _ in () }.eraseToAnyPublisher(),
                          live.$worn.map { _ in () }.eraseToAnyPublisher(),
                          live.$heartRate.map { _ in () }.eraseToAnyPublisher(),
                          live.$rr.map { _ in () }.eraseToAnyPublisher()] {
            publisher.dropFirst().sink { [weak self] _ in self?.evaluate(now: Self.now()) }
                .store(in: &activeCancellables)
        }
        Timer.publish(every: 15, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in
                let now = Int(date.timeIntervalSince1970)
                self?.evaluate(now: now)
                self?.refreshCheckIn(now: now)
            }
            .store(in: &activeCancellables)
        Task { [weak self] in await self?.refreshEvidence() }
    }

    private func deactivate() {
        activeCancellables.removeAll()
    }
}
