#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
  echo 'Usage: build-app.sh [release|debug]' >&2
  exit 2
fi
swift build --package-path "$APP_ROOT" -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$APP_ROOT" -c "$CONFIGURATION" --show-bin-path)"
APP_BUNDLE="$APP_ROOT/dist/SampleGlide.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
# Replace the generated bundle; merging can retain artwork from an older SwiftPM layout.
RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/SampleBrowser_SampleBrowserAssets.bundle"
rm -rf "$RESOURCE_BUNDLE"
ditto "$BIN_DIR/SampleBrowser_SampleBrowserAssets.bundle" "$RESOURCE_BUNDLE"
"$APP_ROOT/scripts/build-icon.sh" "$APP_ROOT/Assets/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
"$APP_ROOT/scripts/build-icon-catalog.sh" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/SampleGlide" "$APP_BUNDLE/Contents/MacOS/SampleGlide"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SampleGlide</string>
<key>CFBundleIdentifier</key><string>jp.samplebrowser.app</string>
<key>CFBundleName</key><string>SampleGlide</string>
<key>CFBundleDisplayName</key><string>SampleGlide</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
if [[ -f "$APP_BUNDLE/Contents/Resources/Assets.car" ]]; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP_BUNDLE/Contents/Info.plist"
fi
codesign --force --sign - "$APP_BUNDLE"
touch "$APP_BUNDLE"
printf '%s\n' "$APP_BUNDLE"
