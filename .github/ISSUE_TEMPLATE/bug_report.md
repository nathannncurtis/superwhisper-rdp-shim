---
name: Bug report
about: Something doesn't work
title: ''
labels: bug
assignees: ''
---

**What you expected to happen**

**What actually happened**

**Steps to reproduce**

**Environment**
- macOS version:
- Superwhisper version:
- Remote client and version (Windows App, RemotePC, etc.):

**Probe output**

For anything input-related this is the most useful thing you can attach. Stop the
agent and run the binary directly with `--probe`, reproduce the problem, and paste
the log — it records every keyboard event with the process that posted it.

```
launchctl bootout gui/$(id -u)/com.nathan.swshim
~/Applications/SuperwhisperRDPShim.app/Contents/MacOS/SuperwhisperRDPShim --probe
```
