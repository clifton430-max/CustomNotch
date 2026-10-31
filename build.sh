#!/bin/zsh
# Builds CustomNotch.app (menu-bar only, no Dock icon) and optionally launches it.
#   ./build.sh        build
#   ./build.sh run    build, then (re)launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=CustomNotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CustomNotch "$APP/Contents/MacOS/CustomNotch"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CustomNotch</string>
    <key>CFBundleDisplayName</key><string>CustomNotch</string>
    <key>CFBundleIdentifier</key><string>com.customnotch.app</string>
    <key>CFBundleExecutable</key><string>CustomNotch</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $PWD/$APP"

if [[ "${1:-}" == "run" ]]; then
    pkill -x CustomNotch 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi
