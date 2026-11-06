#!/bin/bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo 'Usage: setup-notarization.command' >&2
  exit 2
fi
if [[ ! -t 0 ]]; then
  echo 'Run this script in Terminal; Apple credentials are entered interactively.' >&2
  exit 1
fi
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-sampleglide-notary}"
echo "Saving Apple notarization credentials to Keychain profile: $PROFILE"
echo 'Use your Developer Apple Account, 10-character Team ID, and an app-specific password.'
echo 'Create the app-specific password at https://account.apple.com/ (Sign-In and Security).'
echo 'Enter it only in the secure notarytool prompt, never in chat or a repository file.'
exec xcrun notarytool store-credentials "$PROFILE"
