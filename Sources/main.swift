import Cocoa
import Carbon.HIToolbox

// MARK: - Configuration

/// Remote-desktop clients whose sessions need typed input instead of a paste.
/// Add a bundle identifier here to cover another client (RemotePC is
/// com.idrive.RemotePCSuite) -- the rest of the logic is client-agnostic.
let remoteClientBundleIDs: Set<String> = [
    "com.microsoft.rdc.macos",
]

let superwhisperBundleID = "com.superduper.superwhisper"

/// Human-readable names for the same targets, for the menu.
let remoteClientNames: [String] = remoteClientBundleIDs.compactMap { bundleID in
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        return bundleID
    }
    return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
}.sorted()

// MARK: - Shim

final class Shim {

    /// Probe mode logs every keyboard event and suppresses nothing. Use it to see
    /// exactly what Superwhisper emits, and to confirm that synthetic events really
    /// do carry their posting process's PID on this macOS version.
    private let probeOnly: Bool

    init(probeOnly: Bool) {
        self.probeOnly = probeOnly
    }

    private var eventTap: CFMachPort?

    /// Superwhisper can run more than one process; we care about any of them.
    private var superwhisperPIDs: Set<pid_t> = []

    /// Cached so the tap callback never has to make a cross-process query.
    private var frontmostBundleID: String?

    /// PIDs already checked and ruled out, so we resolve each path only once.
    private var knownForeignPIDs: Set<pid_t> = []

    /// Guards against a second paste arriving mid-type.
    private var isTyping = false

    private let typeQueue = DispatchQueue(label: "swshim.type", qos: .userInitiated)

    // MARK: Lifecycle

    func start() {
        requireAccessibility()

        refreshSuperwhisperPIDs()
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observeWorkspace()

        guard installTap() else {
            Log.error("Failed to create event tap.")
            exit(1)
        }

        if probeOnly {
            Log.info("PROBE MODE -- logging only, nothing will be suppressed or typed")
        } else {
            Log.info("watching for dictation pastes into \(remoteClientBundleIDs.joined(separator: ", "))")
        }
        Log.info("superwhisper pid(s): \(superwhisperPIDs.isEmpty ? "none running (any sender is still intercepted)" : superwhisperPIDs.map(String.init).joined(separator: ", "))")
    }

    /// Exit if Accessibility isn't granted, and let launchd's KeepAlive respawn us.
    ///
    /// Waiting in-process looks tidier but cannot work: AXIsProcessTrusted() caches
    /// its answer for the lifetime of the process, so a poll loop keeps reporting
    /// "denied" long after the box is ticked. Only a fresh process sees the grant.
    /// launchd throttles respawns to ~10s, so this self-heals shortly after the tick.
    private func requireAccessibility() {
        if AXIsProcessTrusted() { return }

        // Show the system dialog at most once, ever. Because launchd respawns us on
        // a timer until the permission lands, prompting on every launch would put a
        // dialog on screen every few seconds until the user gave in -- which is
        // nagging, not asking. Ask once, then retry silently.
        let askedBefore = UserDefaults.standard.bool(forKey: "HasPromptedForAccessibility")
        if !askedBefore {
            UserDefaults.standard.set(true, forKey: "HasPromptedForAccessibility")
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            Log.warn("requested Accessibility permission (asking once; will retry silently)")
        }

        Log.warn("no Accessibility permission yet -- exiting so launchd respawns us")
        Log.warn("System Settings > Privacy & Security > Accessibility -- add SuperwhisperRDPShim")
        exit(0)
    }

    // MARK: Workspace tracking

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBundleID = app?.bundleIdentifier
        }

        for name: NSNotification.Name in [NSWorkspace.didLaunchApplicationNotification,
                                          NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshSuperwhisperPIDs()
            }
        }
    }

    /// Is this PID part of Superwhisper?
    ///
    /// NSWorkspace only lists GUI applications, so a helper or XPC process posting
    /// the paste on the main app's behalf would not appear there. Fall back to
    /// resolving the executable path and checking whether it lives inside the bundle.
    private func isSuperwhisper(_ pid: pid_t) -> Bool {
        if superwhisperPIDs.contains(pid) { return true }
        if knownForeignPIDs.contains(pid) { return false }

        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }

        let path = String(cString: buffer)
        if path.localizedCaseInsensitiveContains("superwhisper.app") {
            superwhisperPIDs.insert(pid)
            Log.info("recognised Superwhisper helper: \(path) (pid \(pid))")
            return true
        }

        knownForeignPIDs.insert(pid)
        return false
    }

    private func refreshSuperwhisperPIDs() {
        knownForeignPIDs.removeAll()
        superwhisperPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == superwhisperBundleID }
                .map { $0.processIdentifier }
        )
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let shim = Unmanaged<Shim>.fromOpaque(userInfo).takeUnretainedValue()
            return shim.handle(type: type, event: event)
        }

        // .defaultTap (rather than .listenOnly) is what lets us swallow the paste,
        // and .headInsertEventTap puts us ahead of the client in the delivery chain.
        eventTap = CGEvent.tapCreate(tap: .cghidEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: mask,
                                     callback: callback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())

        guard let eventTap else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    /// Decide the fate of a single keyboard event.
    ///
    /// Everything not matching all three conditions -- synthetic, from Superwhisper,
    /// while a remote client is frontmost -- passes through untouched. Your own
    /// Cmd+V, and Superwhisper pasting into any normal Mac app, are unaffected.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)

        // The system disables a tap that takes too long; bring it back.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            Log.warn("tap was disabled; re-enabled")
            return nil
        }

        if probeOnly {
            logEvent(type: type, event: event)
            return passThrough
        }

        // Never act on our own synthetic keystrokes.
        if event.getIntegerValueField(.eventSourceUserData) == Typist.magic {
            return passThrough
        }

        // A PID of 0 means the event came from real hardware -- your own hands.
        // Those we never touch. Everything else was posted by some process.
        let postingPID = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        guard postingPID != 0 else { return passThrough }

        // Superwhisper is what we are here for, but we deliberately do not *require*
        // it. Any synthetic Cmd+V arriving while a remote client is frontmost is a
        // paste that cannot work, whoever sent it -- retyping it is strictly better
        // than letting it through to become a stray "v".
        let fromSuperwhisper = isSuperwhisper(postingPID)

        guard let front = frontmostBundleID, remoteClientBundleIDs.contains(front) else {
            return passThrough
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Swallow Superwhisper's synthetic modifier events. If a bare Command or
        // Option reaches the guest it reads as a Windows-key or Alt tap, which opens
        // the Start menu or the menu bar and then eats the characters we type next.
        if type == .flagsChanged {
            return nil
        }

        guard keyCode == CGKeyCode(kVK_ANSI_V) else {
            return passThrough
        }

        // The key-up half of a paste we already swallowed; drop it too.
        if type == .keyUp {
            return nil
        }

        // Cmd+V or Ctrl+V. Which one a dictation tool sends varies -- Superwhisper
        // sends Cmd+V, Handy sends Ctrl+V -- and neither works in a remote session,
        // so both are ours to intercept.
        let isPasteChord = event.flags.contains(.maskCommand) || event.flags.contains(.maskControl)
        guard isPasteChord else {
            return passThrough
        }

        // This is the paste. Read the clipboard now, at intercept time, before
        // Superwhisper has a chance to restore whatever was there before.
        let clipboard = NSPasteboard.general.string(forType: .string)

        guard let text = clipboard, !text.isEmpty else {
            Log.warn("intercepted a paste but the clipboard was empty; letting it through")
            return passThrough
        }

        guard !isTyping else {
            Log.warn("already typing; dropped an overlapping paste")
            return nil
        }

        isTyping = true
        let sender = fromSuperwhisper
            ? "Superwhisper"
            : (NSRunningApplication(processIdentifier: postingPID)?.localizedName ?? "pid \(postingPID)")
        Log.info("intercepted \(sender) paste into \(front) -- typing \(text.count) char(s)")

        typeQueue.async { [weak self] in
            Typist.type(text)
            DispatchQueue.main.async { self?.isTyping = false }
        }

        return nil  // swallow the broken paste
    }

    // MARK: Probe

    private func logEvent(type: CGEventType, event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let userData = event.getIntegerValueField(.eventSourceUserData)

        let kind: String
        switch type {
        case .keyDown:      kind = "keyDown"
        case .keyUp:        kind = "keyUp"
        case .flagsChanged: kind = "flags"
        default:            kind = "other(\(type.rawValue))"
        }

        var mods: [String] = []
        if event.flags.contains(.maskCommand)   { mods.append("cmd") }
        if event.flags.contains(.maskShift)     { mods.append("shift") }
        if event.flags.contains(.maskAlternate) { mods.append("opt") }
        if event.flags.contains(.maskControl)   { mods.append("ctrl") }
        if event.flags.contains(.maskSecondaryFn) { mods.append("fn") }

        // Which process posted this, and is it Superwhisper?
        let origin: String
        if pid == 0 {
            origin = "hardware"
        } else if superwhisperPIDs.contains(pid) {
            origin = "SUPERWHISPER(pid \(pid))"
        } else {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            origin = "\(name)"
        }

        var line = "\(kind.padding(toLength: 7, withPad: " ", startingAt: 0)) key=\(keyCode)"
        if !mods.isEmpty { line += " [\(mods.joined(separator: "+"))]" }
        line += " from=\(origin) front=\(frontmostBundleID ?? "?")"
        if userData != 0 { line += " userData=\(userData)" }

        Log.info(line)
    }
}

// MARK: - Entry point

setbuf(stdout, nil)

/// Owns everything with a lifetime, and brings it up in the right order.
///
/// The status item in particular has to wait for `applicationDidFinishLaunching`.
/// Creating one before AppKit has finished launching silently does nothing -- the
/// call succeeds, no icon appears, and the process looks fine from the outside.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let probeOnly: Bool
    private var shim: Shim?
    private var menuBar: MenuBarController?

    init(probeOnly: Bool) {
        self.probeOnly = probeOnly
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shim = Shim(probeOnly: probeOnly)
        shim.start()
        self.shim = shim

        // Probe runs are throwaway diagnostic sessions from a terminal; they have
        // no business adding an icon to the menu bar.
        if !probeOnly {
            menuBar = MenuBarController(targetNames: remoteClientNames)
        }
    }
}

// .accessory: a status-bar item and a settings panel, but no Dock tile and no
// menu bar of our own. AppKit also owns the run loop, which the event tap needs.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Held at top level because NSApplication.delegate is a weak reference.
let delegate = AppDelegate(probeOnly: CommandLine.arguments.contains("--probe"))
app.delegate = delegate

app.run()
