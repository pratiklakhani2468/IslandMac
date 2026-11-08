#!/bin/zsh
# Build IslandMac, wrap it in an .app bundle, replace any running copy, launch it, and report what's running.
# Usage: scripts/run.sh [--state resting|hover|expanded]
set -euo pipefail
cd "${0:A:h}/.."

# Command Line Tools 27 ship the macOS 27 SDK, where SwiftUI's @State is a macro, but not SwiftUI's
# macro plugin, so nothing with @State compiles. Until Xcode is installed, build against the macOS 26
# SDK the Command Line Tools also include.
DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [[ -z "${SDKROOT:-}" && "$DEVELOPER_DIR_PATH" == */CommandLineTools \
      && ! -e "$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    OLDER_SDK="$(ls -d "$DEVELOPER_DIR_PATH"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$OLDER_SDK" ]]; then
        export SDKROOT="$OLDER_SDK"
        echo "--- building against ${SDKROOT:t} (Command Line Tools lack SwiftUI's macro plugin)"
    fi
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/IslandMac"

APP="build/IslandMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/IslandMac"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.islandmac</string>
    <key>CFBundleName</key><string>IslandMac</string>
    <key>CFBundleExecutable</key><string>IslandMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key><string>IslandMac reads the current track from Music and controls playback from the island.</string>
</dict>
</plist>
PLIST
# A stable signing identity keeps the Automation (Music) permission across rebuilds; ad-hoc signing
# changes identity every build and macOS would ask again.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^Authority=Apple Development|^Signature=adhoc" || true

pkill -x IslandMac 2>/dev/null && sleep 0.5 || true

EXE="$PWD/$APP/Contents/MacOS/IslandMac"
nohup "$EXE" "$@" > build/islandmac.log 2>&1 &
disown
sleep 1.5

echo "--- running IslandMac processes"
pgrep -lf "IslandMac.app/Contents/MacOS/IslandMac" || echo "NOT RUNNING"
echo "--- build/islandmac.log"
cat build/islandmac.log
