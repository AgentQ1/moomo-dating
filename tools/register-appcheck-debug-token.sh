#!/usr/bin/env bash
# Registers an App Check DEBUG token for the Moomo iOS app (moomo-c7a37),
# then proves the registration by exchanging it for a real App Check token —
# the exact call the app makes before every callable.
#
# Usage: tools/register-appcheck-debug-token.sh <debug-token> [display-name]
#
# <debug-token> is the UUID a DEBUG build prints at launch (framed with
# [Moomo]) — each install (device or simulator) has its own. Requires
# `gcloud auth` credentials with access to moomo-c7a37.
#
# This does NOT weaken App Check: enforcement stays on, and only builds
# holding a registered token pass. See backend/README.md "App Check".
set -euo pipefail

TOKEN_VALUE="${1:?usage: $0 <debug-token> [display-name]}"
DISPLAY_NAME="${2:-Registered $(date +%F) via register-appcheck-debug-token.sh}"

PROJECT="moomo-c7a37"
APP_ID="1:998689337464:ios:ca57cd2d8363fae941fd8d"
API="https://firebaseappcheck.googleapis.com/v1/projects/$PROJECT/apps/$APP_ID"
ACCESS_TOKEN="$(gcloud auth print-access-token)"

echo "Registering debug token as '$DISPLAY_NAME'..."
curl -sf -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "x-goog-user-project: $PROJECT" \
  -H "Content-Type: application/json" \
  -d "{\"displayName\": \"$DISPLAY_NAME\", \"token\": \"$TOKEN_VALUE\"}" \
  "$API/debugTokens" >/dev/null
echo "Registered."

API_KEY="$(plutil -extract API_KEY raw "$(dirname "$0")/../app/Moomo/GoogleService-Info.plist")"
echo "Verifying exchange (the call the app itself makes)..."
RESPONSE="$(curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"debugToken\": \"$TOKEN_VALUE\"}" \
  "$API:exchangeDebugToken?key=$API_KEY")"
if printf '%s' "$RESPONSE" | grep -q '"token"'; then
  echo "Exchange OK — this install can now mint App Check tokens."
else
  echo "Exchange still failing:"
  printf '%s\n' "$RESPONSE"
  exit 1
fi
