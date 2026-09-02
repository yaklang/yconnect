#!/usr/bin/env bash
set -euo pipefail

ARTIFACT="${1:?usage: macos-notarize.sh <app-or-dmg>}"
[[ -e "$ARTIFACT" ]] || { echo "Artifact does not exist: $ARTIFACT" >&2; exit 1; }
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

xcrun notarytool submit "$ARTIFACT" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
