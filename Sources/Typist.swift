import Foundation
import Carbon.HIToolbox

/// Types text into a remote-desktop session as real synthetic key events.
///
/// The whole reason this file exists: Superwhisper delivers text by putting it on
/// the clipboard and posting Cmd+V. Neither half of that survives a Windows App
/// session. Cmd+V isn't paste in the guest, and because Superwhisper sets Command
/// as an event *flag* rather than pressing a modifier key, the client's scancode
/// translator has no modifier to forward -- so the guest receives a bare "v".
///
/// So we don't paste. We type, one key position at a time, the way a keyboard would.
enum Typist {

    /// Marks our own events so nothing downstream (including our own tap, and
    /// Superwhisper's hotkey listener) mistakes them for human input.
    static let magic: Int64 = 0x5753_4849_4D00  // "WSHIM"

    /// Modifiers we force back up before typing, so a stuck Command or Option
    /// doesn't turn our first characters into guest shortcuts. Caps Lock (57) and
    /// Fn (63) are deliberately absent: Caps Lock is a toggle we must not flip, and
    /// Fn is the user's push-to-talk key -- it belongs to them, not us.
    private static let modifierKeyCodes: [CGKeyCode] = [
        CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand),
        CGKeyCode(kVK_Shift),   CGKeyCode(kVK_RightShift),
        CGKeyCode(kVK_Option),  CGKeyCode(kVK_RightOption),
        CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl),
    ]

    /// Per-character pause. Too fast and the client drops keys on its way to the
    /// guest; too slow and long dictations crawl. 16ms is about one frame.
    static var perCharDelay: useconds_t = {
        let ms = UserDefaults.standard.integer(forKey: "TypeDelayMs")
        let clamped = (ms >= 1 && ms <= 200) ? ms : 16
        return useconds_t(clamped * 1000)
    }()

    /// Type `raw` as key events. Returns the number of characters actually sent.
    @discardableResult
    static func type(_ raw: String) -> Int {
        let (text, dropped) = AnsiKeymap.sanitize(raw)
        guard !text.isEmpty else {
            Log.warn("nothing typeable in transcript (\(raw.count) chars in)")
            return 0
        }
        if !dropped.isEmpty {
            Log.warn("dropped \(dropped.count) untypeable char(s): \(String(dropped))")
        }

        // A private source keeps our synthetic stream from inheriting the state of
        // whatever the hardware is currently doing.
        guard let source = CGEventSource(stateID: .privateState) else {
            Log.error("could not create event source")
            return 0
        }

        releaseModifiers(source)

        var shiftHeld = false
        var sent = 0

        for ch in text {
            guard let stroke = AnsiKeymap.map[ch] else { continue }

            // Hold Shift across consecutive capitals instead of tapping it per key.
            if stroke.shift != shiftHeld {
                setShift(stroke.shift, source)
                shiftHeld = stroke.shift
            }

            tap(stroke.keyCode, source, shifted: shiftHeld)
            sent += 1
            usleep(perCharDelay)
        }

        if shiftHeld { setShift(false, source) }

        Log.info("typed \(sent) char(s)")
        return sent
    }

    // MARK: - Event construction

    /// Press and release one key position.
    ///
    /// The `shifted` flag has to be set on the character event itself, not just
    /// implied by the Shift key press: a scancode client reads the flags to decide
    /// whether the guest sees an uppercase letter.
    private static func tap(_ keyCode: CGKeyCode, _ source: CGEventSource, shifted: Bool) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                     virtualKey: keyCode,
                                     keyDown: isDown) else { continue }
            if shifted {
                event.flags.insert(.maskShift)
            }
            event.setIntegerValueField(.eventSourceUserData, value: magic)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Press or release the Shift key as a genuine modifier event.
    ///
    /// Critically, we do *not* touch `.flags` or `.type` here. CGEvent already
    /// builds a modifier event carrying device-side bits that say which physical
    /// key fired, and assigning `.flags` throws those bits away -- which is exactly
    /// the mistake that makes scancode clients forward a bare letter. Setting
    /// `.type` is a no-op. Leave both alone.
    private static func setShift(_ down: Bool, _ source: CGEventSource) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_Shift),
                                  keyDown: down) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: magic)
        event.post(tap: .cghidEventTap)
        usleep(perCharDelay)
    }

    /// Force every modifier up, so we start from a known-clean keyboard state.
    private static func releaseModifiers(_ source: CGEventSource) {
        for keyCode in modifierKeyCodes {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keyCode,
                                      keyDown: false) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: magic)
            event.post(tap: .cghidEventTap)
        }
        usleep(20_000)
    }
}
