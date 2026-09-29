#!/bin/bash
# Builds, installs to ~/Applications, and registers a login agent.
set -euo pipefail

cd "$(dirname "$0")"

APP="SuperwhisperRDPShim.app"
DEST="$HOME/Applications"
LABEL="com.nathan.swshim"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/swshim.log"

./build.sh

# Stop any running copy before replacing it on disk.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"
echo "installed: $DEST/$APP"

mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/$APP/Contents/MacOS/SuperwhisperRDPShim</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>          <true/>
    <!-- Retry slowly while waiting for Accessibility. A fresh process is the only
         thing that can observe the grant, but there is no reason to churn. -->
    <key>ThrottleInterval</key>   <integer>30</integer>
    <key>StandardOutPath</key>    <string>$LOG</string>
    <key>StandardErrorPath</key>  <string>$LOG</string>
</dict>
</plist>
PLISTEOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "login agent registered: $PLIST"
echo
echo "Log: $LOG"
echo
echo "One-time step: grant Accessibility permission."
echo "  System Settings > Privacy & Security > Accessibility"
echo "  Add: $DEST/$APP"
echo
echo "The agent asks once, then retries silently every 30s. Tick the box and it"
echo "picks the permission up on its own -- no relaunch needed."
