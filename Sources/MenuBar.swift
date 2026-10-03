import Cocoa

/// The status-bar item. The shim has no window of its own and nothing to show
/// while idle, so the menu exists mainly to make an invisible background process
/// legible: proof it's running, what it's watching for, and the one setting worth
/// changing.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let speedLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var settings: SettingsWindowController?

    /// What the tap is watching for, so the menu can describe itself accurately.
    private let targetNames: [String]

    init(targetNames: [String]) {
        self.targetNames = targetNames
        super.init()

        if let icon = NSImage(systemSymbolName: "keyboard.badge.ellipsis",
                              accessibilityDescription: "Superwhisper RDP Shim") {
            icon.isTemplate = true       // so it follows light/dark menu bars
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "SW"
        }

        buildMenu()

        // Worth logging: a status item that fails to materialise does so silently,
        // and menu-bar managers like Ice can hide it, so "I can't see it" is not
        // evidence either way. This line distinguishes the two.
        if statusItem.button != nil {
            Log.info("menu bar item created (a menu-bar manager may be hiding it)")
        } else {
            Log.warn("menu bar item could NOT be created")
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        speedLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(speedLine)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Typing Speed…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logItem = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Refresh the read-only lines each time the menu opens, so the speed shown is
    /// the speed that will actually be used -- it can be changed from a terminal too.
    func menuWillOpen(_ menu: NSMenu) {
        let running = !NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == superwhisperBundleID }
            .isEmpty
        // Superwhisper is no longer the only sender worth catching -- any tool that
        // pastes into a remote session gets the same treatment -- so its absence is
        // information, not a fault.
        statusLine.title = "Watching \(targetNames.joined(separator: ", "))"
            + (running ? "" : " · Superwhisper not running")

        let ms = Preferences.typeDelayMs
        speedLine.title = "Typing at \(ms) ms/char"
            + (ms == Preferences.defaultDelayMs ? " (default)" : "")
    }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindowController() }
        settings?.present()
    }

    @objc private func openLog() {
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/swshim.log")
        NSWorkspace.shared.open(log)
    }

    /// Quit properly, by unloading the login agent.
    ///
    /// Simply exiting would be a lie: launchd's KeepAlive would restart the process
    /// within seconds and the menu bar icon would reappear. Booting the job out is
    /// what a user means by "quit". It comes back at next login.
    @objc private func quit() {
        let label = "gui/\(getuid())/com.nathan.swshim"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", label]
        try? task.run()

        // If it wasn't started by launchd (running straight from a terminal, say),
        // bootout does nothing and we still need to go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}
