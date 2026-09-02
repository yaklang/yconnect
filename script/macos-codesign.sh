#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:?usage: macos-codesign.sh <YConnect.app>}"
IDENTITY="${APPLE_CODESIGN_IDENTITY:?APPLE_CODESIGN_IDENTITY is required}"

[[ -d "$APP_PATH" && -x "$APP_PATH/Contents/MacOS/YConnect" ]] || {
    echo "Invalid YConnect app bundle: $APP_PATH" >&2
    exit 1
}

codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
