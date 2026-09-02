#!/usr/bin/env bash
set -euo pipefail

ARTIFACT="${1:?usage: macos-notarize.sh <app-or-dmg-or-pkg>}"
[[ -e "$ARTIFACT" ]] || { echo "Artifact does not exist: $ARTIFACT" >&2; exit 1; }
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required}"

SUBMISSION="$ARTIFACT"
STAPLE_TARGET="$ARTIFACT"
NOTARY_TMP_DIR=""
cleanup() {
    if [[ -n "$NOTARY_TMP_DIR" ]]; then
        rm -rf "$NOTARY_TMP_DIR"
    fi
}
trap cleanup EXIT

case "$ARTIFACT" in
    *.app)
        [[ -d "$ARTIFACT" ]] || { echo "App bundle is not a directory: $ARTIFACT" >&2; exit 1; }
        NOTARY_TMP_DIR="$(mktemp -d)"
        SUBMISSION="$NOTARY_TMP_DIR/$(basename "$ARTIFACT").zip"
        # notarytool does not accept a bare .app. Preserve its parent directory
        # in a temporary ZIP, then staple the accepted ticket to the source app.
        ditto -c -k --keepParent "$ARTIFACT" "$SUBMISSION"
        ;;
    *.dmg|*.pkg)
        [[ -f "$ARTIFACT" ]] || { echo "Artifact is not a regular file: $ARTIFACT" >&2; exit 1; }
        ;;
    *)
        echo "Unsupported artifact; provide a signed .app, .dmg, or .pkg: $ARTIFACT" >&2
        exit 1
        ;;
esac

xcrun notarytool submit "$SUBMISSION" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --wait
xcrun stapler staple "$STAPLE_TARGET"
xcrun stapler validate "$STAPLE_TARGET"
