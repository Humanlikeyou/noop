import Foundation
import UserNotifications
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// Posts a local notification explaining why the band was told to vibrate.
@MainActor
protocol LucidDreamNotifying: AnyObject {
    /// `passive` keeps an overnight notice silent and out of the banner (it lands in Notification
    /// Center for the morning) so the notification itself cannot wake the sleeper.
    func post(identifier: String, title: String, body: String, passive: Bool)
}

/// Same delivery rule as `BatteryNotifier`: post only when the OS already authorised notifications, never
/// prompt from here. No sound on any Lucid notice: the wrist cue is the only intended stimulus.
@MainActor
final class StrapBuzzNotifier: LucidDreamNotifying {
    func post(identifier: String, title: String, body: String, passive: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = nil
            content.interruptionLevel = passive ? .passive : .active
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }
}

/// Holds or releases a "prevent idle system sleep" assertion. Lid-closed sleep is not preventable this
/// way; the Settings copy says so.
@MainActor
protocol LucidDreamKeepAwake: AnyObject {
    func setHeld(_ held: Bool)
    var isHeld: Bool { get }
}

@MainActor
final class SystemKeepAwake: LucidDreamKeepAwake {
    #if os(macOS)
    private var assertionID: IOPMAssertionID = 0
    #endif
    private(set) var isHeld = false

    func setHeld(_ held: Bool) {
        guard held != isHeld else { return }
        #if os(macOS)
        if held {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NOOP Lucid Dream Mode is monitoring sleep" as CFString,
                &id)
            guard result == kIOReturnSuccess else { return }
            assertionID = id
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        #endif
        isHeld = held
    }
}
