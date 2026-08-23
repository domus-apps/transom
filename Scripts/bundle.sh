#!/bin/bash
# Builds a standalone Transom.app at build/Transom.app.
# The bundle gets its own Accessibility permission entry, separate from the
# `swift run` dev flow (where the permission belongs to your terminal).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/Transom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Transom "$APP/Contents/MacOS/Transom"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

# Compile the Icon Composer document into Assets.car when one exists —
# no icon assets yet, so this block is a no-op until Assets/AppIcon.icon
# is added (see Oriel's Scripts/make-assets.swift for the approach).
if [[ -d Assets/AppIcon.icon ]]; then
    ICONBUILD=$(mktemp -d)
    xcrun actool Assets/AppIcon.icon --compile "$ICONBUILD" \
        --platform macosx --minimum-deployment-target 26.0 \
        --app-icon AppIcon --output-partial-info-plist "$ICONBUILD/partial.plist" \
        --output-format human-readable-text --errors > /dev/null
    cp "$ICONBUILD/Assets.car" "$APP/Contents/Resources/Assets.car"
    cp "$ICONBUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONBUILD"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
fi

# With CODESIGN_IDENTITY set (e.g. "Developer ID Application"), produce a
# distributable, notarization-ready signature (hardened runtime + timestamp).
# Otherwise fall back to ad-hoc, which keeps the TCC (Accessibility) grant
# stable across rebuilds on this machine.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi

echo "Built $APP"
echo "Run:  open $APP"
