#!/bin/bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 ]]; then
  echo 'Usage: build-icon-catalog.sh [output-directory]' >&2
  exit 2
fi
ICON_OUTPUT_DIR="${1:-$APP_ROOT/.build/AppIconCatalog}"
mkdir -p "$ICON_OUTPUT_DIR"
# A build with an older toolchain must not reuse a previous native icon catalog.
rm -f "$ICON_OUTPUT_DIR/Assets.car"
XCODE_VERSION_OUTPUT="$(xcodebuild -version 2>/dev/null || true)"
XCODE_MAJOR="$(awk '$1 == "Xcode" { split($2, version, "."); print version[1]; exit }' <<< "$XCODE_VERSION_OUTPUT")"
if [[ ! "$XCODE_MAJOR" =~ ^[0-9]+$ ]] || [[ "$XCODE_MAJOR" -lt 26 ]]; then
  echo 'Xcode 26+ is unavailable; using the ICNS app icon fallback.' >&2
  exit 0
fi

# Once a supported Xcode is selected, tool or compilation failures are build errors.
ACTOOL="$(xcrun --find actool)"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SampleBrowserIconCatalog.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICON_DOCUMENT="$ICON_WORK_DIR/AppIcon.icon"
mkdir -p "$ICON_DOCUMENT/Assets" "$ICON_WORK_DIR/Compiled"
cp "$APP_ROOT/Assets/AppIcon.icon.json" "$ICON_DOCUMENT/icon.json"
cp "$APP_ROOT/Assets/AppIcon.png" "$ICON_DOCUMENT/Assets/Artwork.png"
"$ACTOOL" "$ICON_DOCUMENT" \
  --compile "$ICON_WORK_DIR/Compiled" \
  --platform macosx \
  --minimum-deployment-target 14.0 \
  --target-device mac \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_WORK_DIR/Partial.plist" \
  --output-format human-readable-text --warnings --errors
if [[ ! -s "$ICON_WORK_DIR/Compiled/Assets.car" ]]; then
  echo 'The app icon compiler did not produce Assets.car.' >&2
  exit 1
fi
# Keep the complete, original-artwork ICNS produced by build-icon.sh for fallback.
mv "$ICON_WORK_DIR/Compiled/Assets.car" "$ICON_OUTPUT_DIR/Assets.car"
printf '%s\n' "$ICON_OUTPUT_DIR/Assets.car"
