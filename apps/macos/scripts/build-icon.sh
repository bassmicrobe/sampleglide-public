#!/bin/bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 2 ]]; then
  echo 'Usage: build-icon.sh [source.png] [output.icns]' >&2
  exit 2
fi
ICON_SOURCE="${1:-$APP_ROOT/Assets/AppIcon.png}"
ICON_OUTPUT="${2:-$APP_ROOT/.build/AppIcon.icns}"
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'App icon source does not exist: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi

ICON_PROPERTIES="$(sips -g format -g pixelWidth -g pixelHeight "$ICON_SOURCE")"
ICON_FORMAT="$(awk '$1 == "format:" { print $2 }' <<< "$ICON_PROPERTIES")"
ICON_WIDTH="$(awk '$1 == "pixelWidth:" { print $2 }' <<< "$ICON_PROPERTIES")"
ICON_HEIGHT="$(awk '$1 == "pixelHeight:" { print $2 }' <<< "$ICON_PROPERTIES")"
if [[ "$ICON_FORMAT" != "png" || ! "$ICON_WIDTH" =~ ^[0-9]+$ || ! "$ICON_HEIGHT" =~ ^[0-9]+$ ]]; then
  echo 'App icon source must be a PNG image.' >&2
  exit 1
fi
if [[ "$ICON_WIDTH" -ne "$ICON_HEIGHT" || "$ICON_WIDTH" -lt 1024 ]]; then
  echo 'App icon source must be square and at least 1024 x 1024 pixels.' >&2
  exit 1
fi

ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/SampleBrowserIcon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for POINTS in 16 32 128 256 512; do
  for SCALE in 1 2; do
    PIXELS=$((POINTS * SCALE))
    SUFFIX=''
    if [[ "$SCALE" -eq 2 ]]; then
      SUFFIX='@2x'
    fi
    sips -s format png -z "$PIXELS" "$PIXELS" "$ICON_SOURCE" \
      --out "$ICONSET/icon_${POINTS}x${POINTS}${SUFFIX}.png" >/dev/null
  done
done
iconutil -c icns "$ICONSET" -o "$ICON_WORK_DIR/AppIcon.icns"
mkdir -p "$(dirname "$ICON_OUTPUT")"
mv "$ICON_WORK_DIR/AppIcon.icns" "$ICON_OUTPUT"
printf '%s\n' "$ICON_OUTPUT"
