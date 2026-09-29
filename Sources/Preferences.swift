import Foundation

/// Preferences, read and written through CFPreferences rather than UserDefaults.
///
/// The distinction matters here. Settings are changed from the menu bar while a
/// dictation could be moments away, and `defaults write` from a terminal has to
/// work too. CFPreferences with an explicit synchronise is what makes a change
/// visible to this process immediately, instead of serving a cached copy until
/// relaunch.
enum Preferences {

    static let typeDelayKey = "TypeDelayMs"

    /// Conservative default: fast enough to feel responsive, slow enough that the
    /// remote client doesn't drop keys on their way to the guest.
    static let defaultDelayMs = 16

    /// Below 1ms there is no pause at all; above 200ms a sentence takes a minute.
    static let delayRange = 1...200

    /// Milliseconds between characters. Read fresh every time.
    static var typeDelayMs: Int {
        get {
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            let stored = CFPreferencesCopyAppValue(typeDelayKey as CFString,
                                                   kCFPreferencesCurrentApplication) as? Int
            return clamp(stored ?? defaultDelayMs)
        }
        set {
            CFPreferencesSetAppValue(typeDelayKey as CFString,
                                     clamp(newValue) as CFNumber,
                                     kCFPreferencesCurrentApplication)
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
    }

    static func resetTypeDelay() {
        CFPreferencesSetAppValue(typeDelayKey as CFString, nil, kCFPreferencesCurrentApplication)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// Roughly how many characters a second the current pace works out to, for
    /// showing alongside the raw millisecond figure.
    static func charactersPerSecond(forDelayMs ms: Int) -> Int {
        max(1, 1000 / max(ms, 1))
    }

    private static func clamp(_ ms: Int) -> Int {
        min(max(ms, delayRange.lowerBound), delayRange.upperBound)
    }
}
