import Cocoa

/// A small panel for the one thing worth tuning: how fast text is typed into the
/// remote session.
///
/// It's a slider rather than a text field because the right value is found by
/// feel, not arithmetic -- you nudge it down until characters start going missing
/// in the guest, then back off. Changes apply to the next dictation with no
/// restart, so the loop is: drag, speak, judge.
final class SettingsWindowController: NSWindowController {

    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let rateLabel = NSTextField(labelWithString: "")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Typing Speed"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
        syncFromPreferences()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "Typing speed")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.frame = NSRect(x: 20, y: 170, width: 340, height: 18)
        content.addSubview(heading)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .regular)
        valueLabel.frame = NSRect(x: 20, y: 132, width: 200, height: 28)
        content.addSubview(valueLabel)

        rateLabel.font = .systemFont(ofSize: 11)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.alignment = .right
        rateLabel.frame = NSRect(x: 180, y: 139, width: 180, height: 16)
        content.addSubview(rateLabel)

        slider.minValue = Double(Preferences.delayRange.lowerBound)
        slider.maxValue = 60          // the useful range; the field clamps to 200
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.frame = NSRect(x: 20, y: 104, width: 340, height: 20)
        content.addSubview(slider)

        let fastLabel = NSTextField(labelWithString: "Faster")
        let slowLabel = NSTextField(labelWithString: "Safer")
        for (label, x, align) in [(fastLabel, 20, NSTextAlignment.left),
                                  (slowLabel, 260, NSTextAlignment.right)] {
            label.font = .systemFont(ofSize: 10)
            label.textColor = .tertiaryLabelColor
            label.alignment = align
            label.frame = NSRect(x: CGFloat(x), y: 86, width: 100, height: 14)
            content.addSubview(label)
        }

        let help = NSTextField(wrappingLabelWithString:
            "Applies to your next dictation — no restart needed. If characters go "
            + "missing in the remote session, raise it.")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 20, y: 44, width: 340, height: 34)
        content.addSubview(help)

        let reset = NSButton(title: "Restore Default", target: self, action: #selector(restoreDefault))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 20, y: 12, width: 130, height: 24)
        content.addSubview(reset)

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 280, y: 12, width: 80, height: 24)
        content.addSubview(done)
    }

    private func syncFromPreferences() {
        let ms = Preferences.typeDelayMs
        slider.doubleValue = Double(ms)
        updateLabels(ms)
    }

    private func updateLabels(_ ms: Int) {
        valueLabel.stringValue = "\(ms) ms"
        let rate = Preferences.charactersPerSecond(forDelayMs: ms)
        rateLabel.stringValue = "about \(rate) characters/sec"
    }

    @objc private func sliderMoved() {
        let ms = Int(slider.doubleValue.rounded())
        Preferences.typeDelayMs = ms
        updateLabels(ms)
    }

    @objc private func restoreDefault() {
        Preferences.resetTypeDelay()
        syncFromPreferences()
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func present() {
        syncFromPreferences()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
