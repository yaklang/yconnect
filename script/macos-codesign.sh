#!/usr/bin/env bash
set -euo pipefail
umask 077
APP_PATH="${1:?usage: macos-codesign.sh <app>}"
[[ -x "$APP_PATH/Contents/MacOS/YConnect" ]] || { echo "Invalid app: $APP_PATH" >&2; exit 1; }
: "${APPLE_CERTIFICATE_BASE64:?APPLE_CERTIFICATE_BASE64 is required}"
: "${APPLE_CERTIFICATE_PASSWORD:?APPLE_CERTIFICATE_PASSWORD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/yconnect-signing.XXXXXX")"
KEYCHAIN="$WORK_DIR/signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
    keychain="${keychain#${keychain%%[![:space:]]*}}"
    keychain="${keychain#\"}"
    keychain="${keychain%\"}"
    [[ -n "$keychain" ]] && ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user)
cleanup() {
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" 2>/dev/null || true
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
printf '%s' "$APPLE_CERTIFICATE_BASE64" | base64 --decode > "$WORK_DIR/certificate.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
security import "$WORK_DIR/certificate.p12" -k "$KEYCHAIN" -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -v team="($APPLE_TEAM_ID)" '/Developer ID Application:/ && index($0, team) {print $2; exit}')"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity for the configured team" >&2; exit 1; }
codesign --force --options runtime --timestamp --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --verbose=4 "$APP_PATH" 2> "$WORK_DIR/signature.txt"
grep -q "^TeamIdentifier=$APPLE_TEAM_ID$" "$WORK_DIR/signature.txt"
grep -q '^Authority=Developer ID Application:' "$WORK_DIR/signature.txt"
echo "Developer ID signature and team verified"
