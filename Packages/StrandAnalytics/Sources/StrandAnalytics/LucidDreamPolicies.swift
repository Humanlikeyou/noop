import Foundation

// LucidDreamPolicies.swift — pure, clock-injected policy helpers for Lucid Dream Mode's app layer.
//
// Kept beside `LucidDreamRemDetector` so every decision that changes when the Mac stays awake, when a
// fresh strap sync is requested, what a pre-sleep training round says, and how a cue explains itself is
// covered by `swift test` with no app, no strap, and no CoreBluetooth.

/// Whether the Mac should hold a "prevent idle sleep" assertion. A sleeping Mac drops the strap's secure
/// link, which silently ends the night's monitoring (observed: the link dropped the same second macOS
/// entered sleep, on two of three real nights).
public enum LucidDreamKeepAwakePolicy {
    /// Local hours treated as "night" even before a sleep session is detected, so the Mac is still
    /// awake when the first offload of the night lands. 19:00 → 11:00.
    public static let nightStartHour = 19
    public static let nightEndHour = 11

    /// Detector states that mean a sleep session is in progress.
    public static let sleepStates: Set<LucidDreamState> = [
        .earlySleep, .monitoring, .possibleREM, .stableREM, .cueSent,
        .observingResponse, .cooldown, .aroused,
    ]

    /// Sleep-stage evidence older than this no longer counts as "asleep now" outside the night window.
    public static let freshEvidenceSeconds = 30 * 60

    /// - Parameter evidenceAgeSeconds: age of the newest stage evidence, or nil when there is none. A
    ///   finished morning session leaves the detector in `.monitoring` with stale evidence all day; only
    ///   fresh evidence extends the hold past the night window (a daytime nap).
    public static func shouldHold(enabled: Bool, keepAwake: Bool, state: LucidDreamState,
                                  localHour: Int, evidenceAgeSeconds: Int? = nil) -> Bool {
        guard enabled, keepAwake else { return false }
        if localHour >= nightStartHour || localHour < nightEndHour { return true }
        guard sleepStates.contains(state), let age = evidenceAgeSeconds else { return false }
        return age <= freshEvidenceSeconds
    }
}

/// When to ask the strap for a fresh history offload. NOOP's ordinary cadence is 15–30 minutes, which
/// left cue decisions acting on stage evidence up to 20 minutes old; inside the REM-watch window a
/// sync every `intervalSeconds` keeps the evidence inside `LucidDreamConfig.maxEvidenceAgeSeconds`.
public enum LucidDreamRefreshPolicy {
    public static let intervalSeconds = 5 * 60

    /// States past the monitoring delay, where a cue could become eligible.
    public static let watchStates: Set<LucidDreamState> = [
        .monitoring, .possibleREM, .stableREM, .cueSent, .observingResponse, .cooldown, .aroused,
    ]

    /// - Parameter sleepingNow: the night window or fresh stage evidence (the keep-awake rule without
    ///   its opt-out). A finished morning session sits in `.monitoring` all day; without this gate it
    ///   would pull a strap offload every 5 minutes until evening.
    public static func shouldRequestSync(state: LucidDreamState, lastRequestAt: Int?, now: Int,
                                         interval: Int = intervalSeconds,
                                         sleepingNow: Bool = true) -> Bool {
        guard sleepingNow, watchStates.contains(state) else { return false }
        guard let last = lastRequestAt else { return true }
        return now - last >= interval
    }
}

/// Pre-sleep cue-association practice (targeted lucidity reactivation). The same wrist cue used during
/// REM is paired, while awake, with a short lucidity routine, so the cue later carries that intention
/// into the dream. One round per `roundSeconds`.
public enum LucidDreamTrainingPlan {
    public static let roundSeconds = 60
    public static let defaultMinutes = 10
    public static let minutesRange: ClosedRange<Int> = 5...20

    public static let prompts: [String] = [
        "Feel the buzz. Ask yourself: am I dreaming right now?",
        "Look around slowly. Notice anything unusual, and check your hands.",
        "Take a breath and notice your body. Is anything strange?",
        "Tell yourself: next time I feel this buzz, I will know I am dreaming.",
    ]

    public static let closingPrompt =
        "Done. Fall asleep repeating: next time I feel the buzz, I will know I am dreaming."

    public static func rounds(minutes: Int) -> Int {
        min(minutesRange.upperBound, max(minutesRange.lowerBound, minutes)) * 60 / roundSeconds
    }

    /// Prompt for 1-based `round`.
    public static func prompt(round: Int) -> String {
        prompts[(max(1, round) - 1) % prompts.count]
    }
}

/// The plain-language reason a sleep cue fired, for the Mac notification and the log.
public enum LucidDreamCueExplanation {
    public static func title(cueNumber: Int, maxCues: Int) -> String {
        "Lucid cue \(cueNumber) of \(maxCues) sent to your band"
    }

    /// - Parameters:
    ///   - remSinceClock: the local clock time REM was first seen (formatted by the caller).
    ///   - remMinutes: how long REM had been held when the cue fired.
    ///   - sinceOnsetMinutes: minutes from sleep onset to the cue.
    public static func body(remSinceClock: String?, remMinutes: Int?, sinceOnsetMinutes: Int?,
                            heartRate: Int?, cueNumber: Int, cueDelaySeconds: Int) -> String {
        var parts: [String] = []
        if let remMinutes {
            let since = remSinceClock.map { " since \($0)" } ?? ""
            parts.append("Likely REM sleep for \(remMinutes) min\(since)")
        } else {
            parts.append("Likely REM sleep")
        }
        if let m = sinceOnsetMinutes {
            parts.append("\(m / 60) h \(m % 60) min after you fell asleep")
        }
        var vitals = "no significant movement"
        if let hr = heartRate { vitals = "HR \(hr) bpm, " + vitals }
        parts.append(vitals)
        let lead = parts.joined(separator: ", ") + "."
        let why = cueNumber > 1
            ? " Repeat cue: no awakening was detected \(cueDelaySeconds) s after the previous one."
            : " The cue is a dream sign meant to prompt lucidity."
        return lead + why
    }
}
