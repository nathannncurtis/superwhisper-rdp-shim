#!/bin/bash
# Builds SuperwhisperRDPShim.app.
#
# It has to be a signed .app bundle, not a bare binary: macOS ties the
# Accessibility grant to a code signature, and an unsigned executable loses the
# permission on every rebuild. The stable --identifier keeps the grant across
# rebuilds so you only approve it once.
set -euo pipefail

cd "$(dirname "$0")"

APP="SuperwhisperRDPShim.app"
IDENT="com.nathan.swshim"

# Sign with a real identity when one exists, falling back to ad-hoc.
#
# This matters more than it looks. TCC binds the Accessibility grant to the code
# signature, and an ad-hoc signature's designated requirement is its cdhash --
# which changes on every single build, silently revoking the permission and making
# the user re-approve. A certificate-backed signature keeps the requirement stable
# across rebuilds, so the grant is given once and stays given.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"[^"]*"' | tr -d '"' | head -1)"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="-"
    echo "warning: no code-signing identity found; falling back to ad-hoc." >&2
    echo "         the Accessibility grant will need re-approving after each build." >&2
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SuperwhisperRDPShim</string>
    <key>CFBundleDisplayName</key>     <string>Superwhisper RDP Shim</string>
    <key>CFBundleIdentifier</key>      <string>com.nathan.swshim</string>
    <key>CFBundleExecutable</key>      <string>SuperwhisperRDPShim</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# The Command Line Tools toolchain is used deliberately: building through
# /Applications/Xcode.app requires agreeing to the Xcode license under sudo, and
# nothing here needs the full Xcode SDK.
CLT="/Library/Developer/CommandLineTools"
SWIFTC="$CLT/usr/bin/swiftc"
[ -x "$SWIFTC" ] || SWIFTC="$(command -v swiftc)"
# Pin to the 26.x SDK: the CLT compiler (6.3) cannot read the 27.0 SDK's
# stdlib module, which was built with Swift 6.4.
SDK="$CLT/SDKs/MacOSX26.sdk"
[ -d "$SDK" ] || SDK="$(DEVELOPER_DIR="$CLT" xcrun --show-sdk-path)"

echo "compiling..."
DEVELOPER_DIR="$CLT" "$SWIFTC" -O -sdk "$SDK" \
    -o "$APP/Contents/MacOS/SuperwhisperRDPShim" \
    Sources/Log.swift \
    Sources/AnsiKeymap.swift \
    Sources/Typist.swift \
    Sources/main.swift \
    -framework Cocoa \
    -framework Carbon

echo "signing as: $SIGN_ID"
codesign --force --sign "$SIGN_ID" --identifier "$IDENT" "$APP"

echo "built: $(pwd)/$APP"
