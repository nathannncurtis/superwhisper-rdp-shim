#!/bin/bash
# Removes the login agent and the installed app. Superwhisper is untouched.
set -euo pipefail
LABEL="com.nathan.swshim"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/SuperwhisperRDPShim.app"
echo "removed. you may also want to drop the stale Accessibility entry in System Settings."
