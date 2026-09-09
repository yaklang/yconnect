#!/usr/bin/env bash
set -euo pipefail
DIST_DIR="${1:?usage: publish-oss.sh <dist-dir> <index-dir>}"
INDEX_DIR="${2:?index directory required}"
VERSION="$(tr -d '[:space:]' < VERSION)"
: "${OSS_ACCESS_KEY_ID:?OSS_ACCESS_KEY_ID is required}"
: "${OSS_ACCESS_KEY_SECRET:?OSS_ACCESS_KEY_SECRET is required}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-https://aliyun-oss.yaklang.com/yconnect}"
OSS_BUCKET="${OSS_BUCKET:-yaklang}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-accelerate.aliyuncs.com}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Read the authoritative index from OSS, avoiding a stale CDN history on reruns.
listing="$(ossutil ls "oss://$OSS_BUCKET/yconnect/releases.json" -e "$OSS_ENDPOINT" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET")"
if [[ "$listing" == *"oss://$OSS_BUCKET/yconnect/releases.json"* ]]; then
    ossutil cp "oss://$OSS_BUCKET/yconnect/releases.json" "$WORK_DIR/previous.json" -e "$OSS_ENDPOINT" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET"
else
    printf '%s\n' '{"schema_version":1,"product":"yconnect","latest":"","versions":[]}' > "$WORK_DIR/previous.json"
fi
EXISTING_RELEASES_FILE="$WORK_DIR/previous.json" bash script/prepare-release-index.sh "$VERSION" "$DIST_DIR/manifest.json" "$INDEX_DIR"

for file in "$DIST_DIR"/*; do
    base="$(basename "$file")"
    object="oss://$OSS_BUCKET/yconnect/$VERSION/$base"
    listing="$(ossutil ls "$object" -e "$OSS_ENDPOINT" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET")"
    if [[ "$listing" == *"$object"* ]]; then
        ossutil cp -f "$object" "$WORK_DIR/existing" -e "$OSS_ENDPOINT" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET"
        cmp "$file" "$WORK_DIR/existing" || { echo "Refusing to overwrite different immutable release file: $base" >&2; exit 1; }
    else
        ossutil cp "$file" "$object" -e "$OSS_ENDPOINT" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET"
    fi
done

# Verify downloads before moving the public version pointers.
CDN_VERIFY_INDEXES=0 bash script/verify-release-cdn.sh "$VERSION" "$DIST_DIR" "$INDEX_DIR"
for name in releases.json latest.json latest.txt latest-version.txt version.txt; do
    ossutil cp -f "$INDEX_DIR/$name" "oss://$OSS_BUCKET/yconnect/$name" \
      --meta 'Content-Type:application/octet-stream#Cache-Control:no-cache,no-transform' \
      -e "$OSS_ENDPOINT" -i "$OSS_ACCESS_KEY_ID" -k "$OSS_ACCESS_KEY_SECRET"
done
bash script/verify-release-cdn.sh "$VERSION" "$DIST_DIR" "$INDEX_DIR"
