#!/bin/bash
# Builds "Claude Profile Switcher.app" into build/, ad-hoc signed.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh install    also copy it to ~/Applications and open it
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Claude Profile Switcher.app"
BIN=ClaudeProfileSwitcher

# Universal when the toolchain can (Xcode installed), the native architecture otherwise.
# Release builds (REQUIRE_UNIVERSAL=1) fail instead of quietly shipping one architecture.
if [[ "${REQUIRE_UNIVERSAL:-}" == 1 ]]; then
    swift build -c release --arch arm64 --arch x86_64
    PRODUCT=".build/apple/Products/Release/$BIN"
elif swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
    PRODUCT=".build/apple/Products/Release/$BIN"
else
    echo "warning: universal build failed; building for $(uname -m) only" >&2
    swift build -c release
    PRODUCT="$(swift build -c release --show-bin-path)/$BIN"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCT" "$APP/Contents/MacOS/$BIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Release builds stamp the tag's version in; local builds keep the one in Info.plist.
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    # CFBundleVersion must be numbers and dots only: 1.2.0-rc.1 becomes 1.2.0.
    plutil -replace CFBundleVersion -string "${VERSION%%[-+]*}" "$APP/Contents/Info.plist"
fi
"$APP/Contents/MacOS/$BIN" --render-app-icon "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc: enough to run on this Mac. macOS ties the Automation permission to this
# signature, so it asks again after each rebuild.
codesign --force --sign - --timestamp=none "$APP"
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/$BIN"))"

if [[ "${1:-}" == "install" ]]; then
    DEST="$HOME/Applications/Claude Profile Switcher.app"
    mkdir -p "$HOME/Applications"
    # Quit a running copy so the new one takes over the menu bar.
    pkill -f "Claude Profile Switcher.app/Contents/MacOS/$BIN\$" || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    open "$DEST"
    echo "Installed: $DEST"
fi
