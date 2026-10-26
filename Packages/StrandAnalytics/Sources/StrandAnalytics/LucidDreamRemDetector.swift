import Foundation

/// Runtime states for the optional lucid-dream cue controller.
public enum LucidDreamState: String, Codable, Sendable {
    case disabled = "DISABLED"
    case waitingForSleep = "WAITING_FOR_SLEEP"
    case earlySleep = "EARLY_SLEEP"
    case monitoring = "MONITORING"
    case possibleREM = "POSSIBLE_REM"
    case stableREM = "STABLE_REM"
    case cueSent = "CUE_SENT"
    case observingResponse = "OBSERVING_RESPONSE"
    case cooldown = "COOLDOWN"
    case aroused = "AROUSED"
}

/// User-tunable lucid-dream cue policy. Times are seconds so the pure engine is easy to test.
public struct LucidDreamConfig: Equatable, Sendable {
    public var enabled: Bool
    public var monitoringDelaySeconds: Int
    public var stableREMSeconds: Int
    public var maxCuesPerEpisode: Int
    public var cueDelaySeconds: Int
    public var stopOnArousal: Bool
    /// The historical stream arrives on NOOP's normal sync cadence. Older evidence is unsafe to act on.
    /// 8 minutes (was 20): with `LucidDreamRefreshPolicy` syncing every 5 minutes in the REM-watch
    /// window, older evidence means the cue would likely land after the REM period has ended.
    public var maxEvidenceAgeSeconds: Int
    /// A real non-REM gap is required before a later REM classification counts as a new episode.
    public var newEpisodeGapSeconds: Int

    public init(enabled: Bool = false,
                monitoringDelaySeconds: Int = 4 * 60 * 60 + 30 * 60,
                stableREMSeconds: Int = 5 * 60,
                maxCuesPerEpisode: Int = 2,
                cueDelaySeconds: Int = 60,
                stopOnArousal: Bool = true,
                maxEvidenceAgeSeconds: Int = 8 * 60,
                newEpisodeGapSeconds: Int = 2 * 60) {
        self.enabled = enabled
        self.monitoringDelaySeconds = monitoringDelaySeconds
        self.stableREMSeconds = stableREMSeconds
        self.maxCuesPerEpisode = maxCuesPerEpisode
        self.cueDelaySeconds = cueDelaySeconds
        self.stopOnArousal = stopOnArousal
        self.maxEvidenceAgeSeconds = maxEvidenceAgeSeconds
        self.newEpisodeGapSeconds = newEpisodeGapSeconds
    }

    var monitoringDelay: Int { max(0, monitoringDelaySeconds) }
    var stableREM: Int { max(30, stableREMSeconds) }
    var maxCues: Int { min(8, max(1, maxCuesPerEpisode)) }
    var cueDelay: Int { max(30, cueDelaySeconds) }
    var maxEvidenceAge: Int { min(30 * 60, max(30, maxEvidenceAgeSeconds)) }
    var newEpisodeGap: Int { max(60, newEpisodeGapSeconds) }
}

/// One causal snapshot. Every sensor timestamp must be at or before `now`.
public struct LucidDreamObservation: Equatable, Sendable {
    public var now: Int
    public var sessionID: String?
    public var sleepOnset: Int?
    public var stage: String?
    public var stageStartedAt: Int?
    public var stageObservedAt: Int?
    public var heartRate: Int?
    public var movement: Double?
    public var movementObservedAt: Int?
    public var significantMovement: Bool
    public var connected: Bool
    public var encryptedBond: Bool
    public var worn: Bool

    public init(now: Int,
                sessionID: String? = nil,
                sleepOnset: Int? = nil,
                stage: String? = nil,
                stageStartedAt: Int? = nil,
                stageObservedAt: Int? = nil,
                heartRate: Int? = nil,
                movement: Double? = nil,
                movementObservedAt: Int? = nil,
                significantMovement: Bool = false,
                connected: Bool = false,
                encryptedBond: Bool = false,
                worn: Bool = true) {
        self.now = now
        self.sessionID = sessionID
        self.sleepOnset = sleepOnset
        self.stage = stage
        self.stageStartedAt = stageStartedAt
        self.stageObservedAt = stageObservedAt
        self.heartRate = heartRate
        self.movement = movement
        self.movementObservedAt = movementObservedAt
        self.significantMovement = significantMovement
        self.connected = connected
        self.encryptedBond = encryptedBond
        self.worn = worn
    }
}

/// Side-effect-free result. The app may send a haptic only when `shouldCue` is true.
public struct LucidDreamDecision: Equatable, Sendable {
    public let state: LucidDreamState
    public let shouldCue: Bool
    public let cueNumber: Int?
    public let status: String
    public let probableArousal: Bool
    public let stopReason: String?

    public init(state: LucidDreamState, shouldCue: Bool = false, cueNumber: Int? = nil,
                status: String, probableArousal: Bool = false, stopReason: String? = nil) {
        self.state = state
        self.shouldCue = shouldCue
        self.cueNumber = cueNumber
        self.status = status
        self.probableArousal = probableArousal
        self.stopReason = stopReason
    }
}

/// Conservative, causal REM cue state machine. It consumes NOOP's existing stage result plus fresh
/// connection, HR, and movement evidence; it never talks to hardware itself.
public struct LucidDreamRemDetector: Sendable {
    public private(set) var state: LucidDreamState = .disabled
    public private(set) var cueCount: Int = 0
    public private(set) var currentSessionID: String?
    public private(set) var suspectedREMAt: Int?
    public private(set) var stableREMAt: Int?
    public private(set) var lastCueAt: Int?
    public private(set) var heartRateBeforeCue: Int?
    public private(set) var movementBeforeCue: Double?

    private var linkWasReady = false
    private var linkReadySince: Int?
    private var nonREMStartedAt: Int?
    private var awaitingNewEpisode = false

    public init() {}

    /// Clear process-local evidence. Persisted configuration is intentionally outside this type.
    public mutating func reset() {
        state = .disabled
        cueCount = 0
        currentSessionID = nil
        suspectedREMAt = nil
        stableREMAt = nil
        lastCueAt = nil
        heartRateBeforeCue = nil
        movementBeforeCue = nil
        linkWasReady = false
        linkReadySince = nil
        nonREMStartedAt = nil
        awaitingNewEpisode = false
    }

    /// Fail closed after the app could not submit an eligible haptic. The failed attempt is not retried;
    /// a sustained non-REM gap must establish a genuinely new episode first.
    public mutating func suppressCurrentEpisode() {
        awaitingNewEpisode = true
        state = .aroused
    }

    public mutating func evaluate(_ observation: LucidDreamObservation,
                                  config: LucidDreamConfig) -> LucidDreamDecision {
        let now = observation.now
        guard config.enabled else {
            reset()
            return decision(.disabled, "Lucid Mode: off")
        }

        let linkReady = observation.connected && observation.encryptedBond && observation.worn
        guard linkReady else {
            if linkWasReady {
                if cueCount > 0 {
                    // A dropped link after a cue makes the response unknowable. Preserve the episode
                    // guard and require a real non-REM gap before any later cue.
                    suspectedREMAt = nil
                    stableREMAt = nil
                    awaitingNewEpisode = true
                } else {
                    clearSessionRuntime()
                }
            }
            linkWasReady = false
            linkReadySince = nil
            let reason: String
            if !observation.connected { reason = "strap disconnected" }
            else if !observation.encryptedBond { reason = "secure strap channel unavailable" }
            else { reason = "strap not worn" }
            state = .waitingForSleep
            return decision(.waitingForSleep, "Lucid Mode: waiting (\(reason))", stopReason: reason)
        }

        // Launch and every reconnect begin a new safety hold. Existing REM history can never cause an
        // immediate cue on the first observation after process/link restoration.
        if !linkWasReady {
            linkWasReady = true
            linkReadySince = now
            if cueCount == 0 { clearSessionRuntime(keepingLink: true) }
        }

        guard let sessionID = observation.sessionID,
              let sleepOnset = observation.sleepOnset,
              sleepOnset <= now else {
            if cueCount > 0 {
                // A transient cache/read gap after a cue must not erase the current episode guard.
                // If data returns with the same session ID, cueing remains suppressed; a genuinely
                // different session still resets normally below.
                suspectedREMAt = nil
                stableREMAt = nil
                awaitingNewEpisode = true
            } else {
                clearSessionRuntime(keepingLink: true)
            }
            state = .waitingForSleep
            return decision(.waitingForSleep, "Lucid Mode: waiting for sleep")
        }

        if currentSessionID != sessionID {
            clearEpisodeRuntime()
            currentSessionID = sessionID
        }

        let monitoringStart = sleepOnset + config.monitoringDelay
        guard now >= monitoringStart else {
            state = .earlySleep
            let remaining = max(0, monitoringStart - now)
            return decision(.earlySleep, "Lucid Mode: early sleep (\(remaining / 60)m remaining)")
        }

        guard let stage = observation.stage?.lowercased(),
              let stageObservedAt = observation.stageObservedAt,
              stageObservedAt >= sleepOnset,
              stageObservedAt <= now,
              now - stageObservedAt <= config.maxEvidenceAge else {
            suspectedREMAt = nil
            stableREMAt = nil
            state = .monitoring
            return decision(.monitoring, "Lucid Mode: monitoring; stage evidence missing or stale",
                            stopReason: "stage evidence missing or stale")
        }

        // Arousal can be established by the existing stage classifier, the movement signal, taking the
        // strap off, or a substantial post-cue HR rise. Any one is enough to suppress this REM episode.
        let awakeStage = stage == "wake" || stage == "awake"
        let heartRateArousal = config.stopOnArousal
            && postCueHeartRateArousal(observation.heartRate)
        let movementArousal = config.stopOnArousal && observation.significantMovement
        let aroused = awakeStage || movementArousal || heartRateArousal
        if aroused {
            suspectedREMAt = nil
            stableREMAt = nil
            awaitingNewEpisode = true
            if awakeStage {
                if nonREMStartedAt == nil {
                    nonREMStartedAt = stageStart(observation, fallback: stageObservedAt)
                }
            } else {
                // Movement/HR arousal can occur while the classifier still says REM. Start the
                // required gap here; an older pre-REM Light segment must not unlock another cue.
                nonREMStartedAt = stageObservedAt
            }
            state = .aroused
            let reason = awakeStage ? "awake stage"
                : movementArousal ? "significant movement" : "heart-rate rise"
            return decision(.aroused, "Cue suppressed: probable arousal (\(reason))",
                            probableArousal: true, stopReason: reason)
        }

        guard stage == "rem" else {
            suspectedREMAt = nil
            stableREMAt = nil
            if nonREMStartedAt == nil { nonREMStartedAt = stageStart(observation, fallback: stageObservedAt) }
            if let gapStart = nonREMStartedAt, stageObservedAt - gapStart >= config.newEpisodeGap {
                clearEpisodeRuntime()
                currentSessionID = sessionID
            }
            state = .monitoring
            return decision(.monitoring, "Lucid Mode: monitoring (\(stage))")
        }

        let evidenceStart = stageStart(observation, fallback: stageObservedAt)
        if awaitingNewEpisode,
           let gapStart = nonREMStartedAt,
           evidenceStart - gapStart >= config.newEpisodeGap {
            clearEpisodeRuntime()
            currentSessionID = sessionID
        }
        nonREMStartedAt = nil
        if awaitingNewEpisode {
            let heldState: LucidDreamState = state == .aroused ? .aroused : .cueSent
            state = heldState
            return decision(heldState, "Lucid Mode: waiting for a new REM episode",
                            stopReason: "cueing complete for this REM episode")
        }

        let safetyStart = max(monitoringStart, linkReadySince ?? now)
        let candidateStart = max(evidenceStart, safetyStart)
        if suspectedREMAt == nil { suspectedREMAt = candidateStart }
        let stableFor = max(0, stageObservedAt - (suspectedREMAt ?? candidateStart))
        guard stableFor >= config.stableREM else {
            state = .possibleREM
            return decision(.possibleREM,
                            "Stable REM \(formatDuration(stableFor)) / \(formatDuration(config.stableREM))")
        }

        if stableREMAt == nil {
            stableREMAt = (suspectedREMAt ?? candidateStart) + config.stableREM
        }
        state = .stableREM

        // A cue needs all required streams. A stage without a contemporaneous HR and movement sample is
        // useful for display, but not strong enough to vibrate a sleeping user.
        guard let movement = observation.movement,
              let movementAt = observation.movementObservedAt,
              movementAt <= now,
              now - movementAt <= config.maxEvidenceAge,
              observation.heartRate != nil else {
            return decision(.stableREM, "Stable REM confirmed; cue withheld (sensor evidence incomplete)",
                            stopReason: "required HR or movement stream missing")
        }

        if cueCount > 0 {
            guard cueCount < config.maxCues else {
                awaitingNewEpisode = true
                state = .cueSent
                return decision(.cueSent, "Lucid Mode: cue limit reached",
                                stopReason: "maximum cues reached")
            }
            guard let lastCueAt else {
                awaitingNewEpisode = true
                state = .aroused
                return decision(.aroused, "Lucid Mode: invalid cue state; stopped",
                                stopReason: "invalid state")
            }
            let elapsed = now - lastCueAt
            guard elapsed >= config.cueDelay else {
                state = .cooldown
                return decision(.cooldown, "Lucid Mode: cooldown (\(config.cueDelay - elapsed)s remaining)")
            }
            // The second cue requires evidence collected after the first. Reusing the same pre-cue REM
            // segment or movement point would be non-causal and could miss an awakening.
            if config.stopOnArousal
                && (stageObservedAt <= lastCueAt || movementAt <= lastCueAt) {
                state = .observingResponse
                return decision(.observingResponse, "Lucid Mode: observing response; awaiting fresh movement",
                                stopReason: "fresh post-cue evidence unavailable")
            }
        }

        cueCount += 1
        lastCueAt = now
        heartRateBeforeCue = observation.heartRate
        movementBeforeCue = movement
        state = .cueSent
        if cueCount >= config.maxCues { awaitingNewEpisode = true }
        return LucidDreamDecision(state: .cueSent, shouldCue: true, cueNumber: cueCount,
                                  status: "Cue \(cueCount) eligible", probableArousal: false,
                                  stopReason: nil)
    }

    private func decision(_ state: LucidDreamState, _ status: String,
                          probableArousal: Bool = false, stopReason: String? = nil) -> LucidDreamDecision {
        LucidDreamDecision(state: state, status: status,
                           probableArousal: probableArousal, stopReason: stopReason)
    }

    private func stageStart(_ observation: LucidDreamObservation, fallback: Int) -> Int {
        guard let start = observation.stageStartedAt, start <= fallback else { return fallback }
        return start
    }

    private func postCueHeartRateArousal(_ current: Int?) -> Bool {
        guard cueCount > 0, let baseline = heartRateBeforeCue, let current else { return false }
        let threshold = max(baseline + 12, Int((Double(baseline) * 1.18).rounded(.up)))
        return current >= threshold
    }

    private mutating func clearSessionRuntime(keepingLink: Bool = false) {
        clearEpisodeRuntime()
        currentSessionID = nil
        if !keepingLink {
            linkReadySince = nil
        }
    }

    private mutating func clearEpisodeRuntime() {
        cueCount = 0
        suspectedREMAt = nil
        stableREMAt = nil
        lastCueAt = nil
        heartRateBeforeCue = nil
        movementBeforeCue = nil
        nonREMStartedAt = nil
        awaitingNewEpisode = false
    }

    private func formatDuration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
