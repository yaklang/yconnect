#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_ROOT="$PROJECT_ROOT/darwin"
RESOURCE_ROOT="$PACKAGE_ROOT/Resources"
OUTPUT_ROOT="$PROJECT_ROOT/dist"
ICON_SOURCE="$RESOURCE_ROOT/YConnectAppIcon.svg"
INFO_PLIST_SOURCE="$RESOURCE_ROOT/Info.plist"

VERSION="$(tr -d '[:space:]' < "$PROJECT_ROOT/VERSION")"
REQUESTED_ARCH="native"
BUILD_DMG=0
DEVELOPMENT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) REQUESTED_ARCH="${2:?--arch requires arm64, amd64, or universal}"; shift 2 ;;
        --universal) REQUESTED_ARCH="universal"; shift ;;
        --version) VERSION="${2:?--version requires a version}"; shift 2 ;;
        --dmg) BUILD_DMG=1; shift ;;
        --dev) DEVELOPMENT=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] || {
    echo "Invalid version: $VERSION" >&2
    exit 1
}

case "$REQUESTED_ARCH" in
    native)
        case "$(uname -m)" in
            arm64) ARCH_LABEL="arm64"; SWIFT_ARCHS=(--arch arm64) ;;
            x86_64) ARCH_LABEL="amd64"; SWIFT_ARCHS=(--arch x86_64) ;;
            *) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 1 ;;
        esac
        ;;
    arm64) ARCH_LABEL="arm64"; SWIFT_ARCHS=(--arch arm64) ;;
    amd64|x86_64) ARCH_LABEL="amd64"; SWIFT_ARCHS=(--arch x86_64) ;;
    universal) ARCH_LABEL="universal"; SWIFT_ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "Unsupported --arch value: $REQUESTED_ARCH" >&2; exit 1 ;;
esac

if [[ "$DEVELOPMENT" -eq 1 ]]; then
    APP_NAME="YConnectDev"
    BUNDLE_IDENTIFIER="io.yaklang.yconnect.dev"
    OUTPUT_LABEL="darwin-dev-$ARCH_LABEL"
else
    APP_NAME="YConnect"
    BUNDLE_IDENTIFIER="io.yaklang.yconnect"
    OUTPUT_LABEL="darwin-$ARCH_LABEL"
fi

APP_OUTPUT_ROOT="$OUTPUT_ROOT/$OUTPUT_LABEL"
APP_BUNDLE="$APP_OUTPUT_ROOT/$APP_NAME.app"
DMG_PATH="$OUTPUT_ROOT/$APP_NAME-$VERSION-darwin-$ARCH_LABEL.dmg"
ICONSET_DIR="$APP_OUTPUT_ROOT/YConnect.iconset"

for command in magick iconutil codesign lipo; do
    command -v "$command" >/dev/null 2>&1 || { echo "Missing packaging command: $command" >&2; exit 1; }
done

rm -rf "$APP_OUTPUT_ROOT"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$ICONSET_DIR"

BUILD_ARGS=(--package-path "$PACKAGE_ROOT" -c release "${SWIFT_ARCHS[@]}")
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
cp "$BIN_PATH/YConnect" "$APP_BUNDLE/Contents/MacOS/YConnect"

BASE_PNG="$APP_OUTPUT_ROOT/YConnectAppIcon-1024.png"
magick -background none "$ICON_SOURCE" -resize 1024x1024 "$BASE_PNG"

render_icon() {
    local size="$1" output="$2"
    magick "$BASE_PNG" -filter Lanczos -resize "${size}x${size}" "$ICONSET_DIR/$output"
}

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
cp "$BASE_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/YConnect.icns"
cp "$INFO_PLIST_SOURCE" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
    BUILD_NUMBER="$GITHUB_RUN_NUMBER"
elif BUILD_NUMBER="$(git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null)"; then
    [[ "$BUILD_NUMBER" -gt 0 ]] || BUILD_NUMBER=1
else
    BUILD_NUMBER=1
fi
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid build number: $BUILD_NUMBER" >&2
    exit 1
}
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

codesign --force --deep --options runtime --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/YConnect")"
case "$ARCH_LABEL:$ARCHS" in
    arm64:arm64|amd64:x86_64) ;;
    universal:*arm64*x86_64*|universal:*x86_64*arm64*) ;;
    *) echo "Packaged architecture mismatch: label=$ARCH_LABEL binary=$ARCHS" >&2; exit 1 ;;
esac

echo "app=$APP_BUNDLE"
echo "version=$VERSION"
echo "architecture=$ARCH_LABEL"
echo "binary_archs=$ARCHS"
echo "development=$DEVELOPMENT"

if [[ "$BUILD_DMG" -eq 1 ]]; then
    "$SCRIPT_DIR/create-macos-dmg.sh" "$APP_BUNDLE" "$VERSION" "$ARCH_LABEL" "$DMG_PATH" >/dev/null
    echo "dmg=$DMG_PATH"
    LC_ALL=C shasum -a 256 "$DMG_PATH"
fi
