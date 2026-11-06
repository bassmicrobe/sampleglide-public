#!/bin/bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != '--check' ) ]]; then
  echo 'Usage: notarize-app.sh [--check]' >&2
  exit 2
fi
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-sampleglide-notary}"
# Prefer full Xcode for distribution without changing the system-wide selection.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# A valid identity includes its private key. Never choose silently between teams.
SIGNING_KEYCHAIN="${CODE_SIGN_KEYCHAIN:-}"
if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  if [[ ! -f "$SIGNING_KEYCHAIN" ]]; then
    echo "Signing keychain does not exist: $SIGNING_KEYCHAIN" >&2
    exit 1
  fi
  IDENTITIES="$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN")"
else
  IDENTITIES="$(security find-identity -v -p codesigning)"
fi
MATCHES=()
while IFS= read -r LINE; do
  HASH="$(sed -nE 's/^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]{40}) "Developer ID Application: .*"$/\1/p' <<< "$LINE")"
  [[ -n "$HASH" ]] || continue
  NAME="${LINE#*\"}"
  NAME="${NAME%\"}"
  if [[ -z "${CODE_SIGN_IDENTITY:-}" || "$CODE_SIGN_IDENTITY" == "$HASH" || "$CODE_SIGN_IDENTITY" == "$NAME" ]]; then
    MATCHES+=("$HASH")
  fi
done <<< "$IDENTITIES"
if [[ ${#MATCHES[@]} -ne 1 ]]; then
  echo 'Exactly one matching Developer ID Application certificate with private key is required.' >&2
  echo 'Set CODE_SIGN_IDENTITY to the intended certificate name or SHA-1 fingerprint.' >&2
  exit 1
fi
SIGNING_IDENTITY="${MATCHES[0]}"
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null
# Check authentication without extracting credentials or sending an application.
if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json >/dev/null; then
  echo "Configure Keychain profile '$PROFILE' with scripts/setup-notarization.command first." >&2
  exit 1
fi
echo 'Developer ID signing identity and notarization credentials are ready.'
[[ "${1:-}" != '--check' ]] || exit 0

# Keep each submitted app independent of later development builds.
mkdir -p "$APP_ROOT/dist/notarization"
RUN_DIR="$(mktemp -d "$APP_ROOT/dist/notarization/run-$(date +%Y%m%d-%H%M%S).XXXXXX")"
echo "Notarization working directory: $RUN_DIR"
APP_OUTPUT_DIR="$RUN_DIR" "$APP_ROOT/scripts/build-app.sh" release
APP_BUNDLE="$RUN_DIR/SampleGlide.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/SampleGlide"
ARCHITECTURES="$(xcrun lipo -archs "$EXECUTABLE")"
read -r -a ARCHITECTURE_LIST <<< "$ARCHITECTURES"
if [[ ${#ARCHITECTURE_LIST[@]} -eq 1 && ( "$ARCHITECTURES" == arm64 || "$ARCHITECTURES" == x86_64 ) ]]; then
  ARCHIVE_ARCHITECTURE="$ARCHITECTURES"
elif [[ ${#ARCHITECTURE_LIST[@]} -eq 2 && " $ARCHITECTURES " == *' arm64 '* && " $ARCHITECTURES " == *' x86_64 '* ]]; then
  ARCHIVE_ARCHITECTURE=universal
else
  echo "Unsupported executable architectures: $ARCHITECTURES" >&2
  exit 1
fi
printf '%s\n' "$ARCHITECTURES" > "$RUN_DIR/architectures.txt"

# The current app has one executable and a resource-only bundle. Future embedded
# frameworks, helpers or plug-ins require their own inside-out signing steps.
SIGNING_OPTIONS=(--force --sign "$SIGNING_IDENTITY" --options runtime --timestamp)
if [[ -n "$SIGNING_KEYCHAIN" ]]; then
  SIGNING_OPTIONS+=(--keychain "$SIGNING_KEYCHAIN")
fi
codesign "${SIGNING_OPTIONS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -d --verbose=4 "$APP_BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$RUN_DIR/submission.zip"

# Persist Apple's ID before waiting, so a timeout is resumable without resending.
xcrun notarytool submit "$RUN_DIR/submission.zip" \
  --keychain-profile "$PROFILE" --output-format json > "$RUN_DIR/submission.json"
cat "$RUN_DIR/submission.json"
SUBMISSION_ID="$(plutil -extract id raw -o - "$RUN_DIR/submission.json")"
if [[ -z "$SUBMISSION_ID" ]]; then
  echo "No submission ID was returned. App and logs retained at: $RUN_DIR" >&2
  exit 1
fi
printf '%s\n' "$SUBMISSION_ID" > "$RUN_DIR/submission-id.txt"
WAIT_EXIT=0
xcrun notarytool wait "$SUBMISSION_ID" \
  --keychain-profile "$PROFILE" --timeout 30m \
  --output-format json > "$RUN_DIR/status.json" || WAIT_EXIT=$?
cat "$RUN_DIR/status.json"
STATUS="$(plutil -extract status raw -o - "$RUN_DIR/status.json" 2>/dev/null || true)"
if [[ "$STATUS" != Accepted || "$WAIT_EXIT" -ne 0 ]]; then
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "$RUN_DIR/notary-log.json" || true
  echo "Check or resume this submission with notarytool info/wait: $SUBMISSION_ID" >&2
  echo "Notarization did not finish with Accepted. App and logs retained at: $RUN_DIR" >&2
  exit 1
fi
xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" "$RUN_DIR/notary-log.json"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=2 "$APP_BUNDLE"

# Distribute the stapled app, then verify the actual ZIP recipients will extract.
ARCHIVE="$RUN_DIR/SampleGlide-macOS-$ARCHIVE_ARCHITECTURE.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ARCHIVE"
(cd "$RUN_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
(cd "$RUN_DIR" && shasum -a 256 --check "$(basename "$ARCHIVE").sha256")
VERIFICATION_DIR="$RUN_DIR/verification"
mkdir "$VERIFICATION_DIR"
ditto -x -k "$ARCHIVE" "$VERIFICATION_DIR"
EXTRACTED_APP="$VERIFICATION_DIR/SampleGlide.app"
xcrun stapler validate "$EXTRACTED_APP"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
spctl --assess --type execute --verbose=2 "$EXTRACTED_APP"
if [[ "$(xcrun lipo -archs "$EXTRACTED_APP/Contents/MacOS/SampleGlide")" != "$ARCHITECTURES" ]]; then
  echo 'Extracted executable architectures differ from the submitted application.' >&2
  exit 1
fi
echo "Verified notarized distribution archive: $ARCHIVE"
