import Foundation
import Combine
import StrandAnalytics

/// Local-only preferences for the optional Lucid Dream Mode. The feature is default-off.
@MainActor
final class LucidDreamSettingsStore: ObservableObject {
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    @Published var monitoringDelayMinutes: Int { didSet { defaults.set(monitoringDelayMinutes, forKey: Key.monitoringDelay) } }
    @Published var stableREMMinutes: Int { didSet { defaults.set(stableREMMinutes, forKey: Key.stableREM) } }
    @Published var maxCuesPerEpisode: Int { didSet { defaults.set(maxCuesPerEpisode, forKey: Key.maxCues) } }
    @Published var cueDelaySeconds: Int { didSet { defaults.set(cueDelaySeconds, forKey: Key.cueDelay) } }
    @Published var stopOnArousal: Bool { didSet { defaults.set(stopOnArousal, forKey: Key.stopOnArousal) } }
    @Published var loggingEnabled: Bool { didSet { defaults.set(loggingEnabled, forKey: Key.logging) } }
    /// Post a Mac notification explaining every Lucid cue the band is told to vibrate. Default on.
    @Published var notifyOnCue: Bool { didSet { defaults.set(notifyOnCue, forKey: Key.notifyOnCue) } }
    /// Hold a prevent-idle-sleep assertion overnight so the strap link survives. Default on.
    @Published var keepMacAwake: Bool { didSet { defaults.set(keepMacAwake, forKey: Key.keepMacAwake) } }
    /// Length of the pre-sleep cue-association practice.
    @Published var trainingMinutes: Int { didSet { defaults.set(trainingMinutes, forKey: Key.trainingMinutes) } }

    private let defaults: UserDefaults

    private enum Key {
        static let enabled = "lucidDream.enabled"
        static let monitoringDelay = "lucidDream.monitoringDelayMinutes"
        static let stableREM = "lucidDream.stableREMMinutes"
        static let maxCues = "lucidDream.maxCuesPerEpisode"
        static let cueDelay = "lucidDream.cueDelaySeconds"
        static let stopOnArousal = "lucidDream.stopOnArousal"
        static let logging = "lucidDream.loggingEnabled"
        static let notifyOnCue = "lucidDream.notifyOnCue"
        static let keepMacAwake = "lucidDream.keepMacAwake"
        static let trainingMinutes = "lucidDream.trainingMinutes"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        monitoringDelayMinutes = Self.clamp(defaults.object(forKey: Key.monitoringDelay) as? Int ?? 270,
                                            to: 60...600)
        stableREMMinutes = Self.clamp(defaults.object(forKey: Key.stableREM) as? Int ?? 5,
                                      to: 1...20)
        maxCuesPerEpisode = Self.clamp(defaults.object(forKey: Key.maxCues) as? Int ?? 2,
                                       to: 1...4)
        cueDelaySeconds = Self.clamp(defaults.object(forKey: Key.cueDelay) as? Int ?? 60,
                                     to: 30...300)
        stopOnArousal = defaults.object(forKey: Key.stopOnArousal) as? Bool ?? true
        loggingEnabled = defaults.object(forKey: Key.logging) as? Bool ?? true
        notifyOnCue = defaults.object(forKey: Key.notifyOnCue) as? Bool ?? true
        keepMacAwake = defaults.object(forKey: Key.keepMacAwake) as? Bool ?? true
        trainingMinutes = Self.clamp(defaults.object(forKey: Key.trainingMinutes) as? Int
                                         ?? LucidDreamTrainingPlan.defaultMinutes,
                                     to: LucidDreamTrainingPlan.minutesRange)
    }

    var detectorConfig: LucidDreamConfig {
        LucidDreamConfig(
            enabled: enabled,
            monitoringDelaySeconds: monitoringDelayMinutes * 60,
            stableREMSeconds: stableREMMinutes * 60,
            maxCuesPerEpisode: maxCuesPerEpisode,
            cueDelaySeconds: cueDelaySeconds,
            stopOnArousal: stopOnArousal)
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
