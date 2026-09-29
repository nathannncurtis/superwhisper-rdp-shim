# SuperwhisperRDPShim

Makes Superwhisper dictation work inside Microsoft Remote Desktop (Windows App)
on macOS. Superwhisper pastes; a remote session can't receive a paste. This types
instead. Same push-to-talk key, no new shortcut, no Superwhisper license needed.

## The bug it fixes

Superwhisper delivers text by writing it to the clipboard and posting a synthetic
**Cmd+V**. In a Windows App session that fails twice over:

1. **Cmd+V isn't paste in the guest.** Windows pastes with Ctrl+V.
2. **The modifier never arrives.** Superwhisper sets Command as an event *flag*
   rather than pressing a modifier key. Windows App translates scancodes, so a
   flag-only modifier gives it no modifier key to forward — the guest receives a
   bare `v`.

That second point is the stray **V** you actually see on screen.

A third problem sits behind both: these clients only re-advertise the clipboard to
the guest after a focus change, so even a correctly-sent Ctrl+V frequently pastes
*stale* text. Typing sidesteps the clipboard in the guest entirely.

## Architecture

One process, one `CGEvent` tap, inserted ahead of the remote client in the
delivery chain:

```
Superwhisper                    SuperwhisperRDPShim                 Windows App
┌────────────────────┐         ┌───────────────────────┐         ┌─────────────┐
│ clipboard := text  │         │ CGEvent tap           │         │  RDP guest  │
│ post synthetic     ├────────►│ posted by Superwhisper?├──┐      │             │
│   Cmd+V            │  HID    │ remote client front?   │  │ no   │             │
└────────────────────┘  tap    └───────────────────────┘  ├─────►│ (unchanged) │
                                           │ yes          │      │             │
                                           ▼              │      │             │
                               ┌───────────────────────┐  │      │             │
                               │ swallow the Cmd+V     │  │      │             │
                               │ read clipboard        │  │      │             │
                               │ type key positions    ├──┼─────►│ "hello"     │
                               │   ~16ms apart         │  │      │             │
                               └───────────────────────┘  │      └─────────────┘
                                                          │
your own Cmd+V (pid 0, hardware) ─────────────────────────┘
```

Events failing either check pass through untouched — your own Cmd+V, and
Superwhisper pasting into any normal Mac app, behave exactly as before.

## Details that matter

- **Key positions, not characters.** Scancode clients forward *where* a key is and
  let the guest translate. Characters are looked up in a US ANSI position table
  (`Sources/AnsiKeymap.swift`); the guest applies its own layout.
- **Modifier events are left untouched.** `CGEvent` builds modifier events carrying
  device-side bits identifying which physical key fired. Assigning `.flags` discards
  those bits — the exact mistake that produces a bare letter. Never touch them.
- **Hardware is identified by PID 0.** Synthetic events carry their posting
  process's PID in `eventSourceUnixProcessID`, which is what distinguishes
  Superwhisper's fake Cmd+V from one you press yourself.
- **Superwhisper's synthetic modifier events are swallowed too.** A bare Command or
  Option reaching the guest reads as a Windows-key or Alt tap, which opens the Start
  menu or menu bar and then eats the characters typed next.
- **Newlines and tabs become spaces.** Synthesizing a real Return into a remote
  session submits whatever form or chat box has focus, with no way to check first.
- **Smart quotes are transliterated,** not dropped — a curly apostrophe silently
  turns "it's" into "its" otherwise.
- **Our own events are tagged** so the tap can't reprocess them and Superwhisper's
  hotkey listener can't mistake them for a keypress.

## Setup

```sh
./install.sh
```

Builds, installs to `~/Applications`, and registers a login agent.

Then grant Accessibility once: **System Settings → Privacy & Security →
Accessibility**, add `SuperwhisperRDPShim`. The agent asks once, then retries
silently every 30s until the permission is there.

Two things make that permission fiddlier than it looks, both handled:

- **Only a fresh process can see the grant.** `AXIsProcessTrusted()` caches its
  answer for the lifetime of a process, so a running instance polling for the
  permission would report "denied" forever. The agent exits instead and lets
  launchd respawn it, which is why it can ask exactly once and still pick the
  grant up later without being relaunched by hand.
- **The grant is bound to the code signature.** `build.sh` signs with the first
  available codesigning identity, which keeps the designated requirement stable
  across rebuilds. Falling back to ad-hoc signing works, but an ad-hoc designated
  requirement is its cdhash — it changes on every build and silently revokes the
  permission, forcing a re-approval each time.

If the permission ever gets into a confused state, clear the record and let it ask
again from scratch:

```sh
tccutil reset Accessibility com.nathan.swshim
defaults delete com.nathan.swshim HasPromptedForAccessibility
```

Log: `~/Library/Logs/swshim.log`

## Configuration

Typing pace, in milliseconds per character (default 16, clamped to 1–200):

```sh
defaults write com.nathan.swshim TypeDelayMs 8
```

Lower is faster; too low and the client starts dropping keys on the way to the
guest.

To cover another remote client, add its bundle identifier to
`remoteClientBundleIDs` in `Sources/main.swift` and rebuild. RemotePC is
`com.idrive.RemotePCSuite`. Only the target list is client-specific; the logic
isn't.

## Debugging

Probe mode logs every keyboard event with its posting process and suppresses
nothing — useful for seeing exactly what Superwhisper emits:

```sh
launchctl bootout gui/$(id -u)/com.nathan.swshim
~/Applications/SuperwhisperRDPShim.app/Contents/MacOS/SuperwhisperRDPShim --probe
```

Running it from a terminal that already holds Accessibility inherits that grant,
which is a convenient way to iterate without re-ticking after every build.

## Repo layout

```
Sources/AnsiKeymap.swift    US ANSI key positions, transliteration, sanitising
Sources/Typist.swift        synthesises the keystrokes
Sources/main.swift          the event tap and interception rules
Sources/Log.swift           timestamped stderr logging
build.sh                    builds + ad-hoc signs the .app
install.sh                  installs to ~/Applications, registers the login agent
uninstall.sh                removes both
```

## Build note

Builds with the Command Line Tools toolchain against the macOS 26 SDK, pinned in
`build.sh`. This avoids `sudo xcodebuild -license`, and the CLT compiler cannot
read the 27.0 SDK's standard library module.

## License

GPL-3.0. See [LICENSE](LICENSE).
