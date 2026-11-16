#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="$ROOT/macos/TopFadeMac"
OUTPUT_ROOT="$ROOT/dist/macos"
APP="$OUTPUT_ROOT/TopFade.app"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Build-Mac.sh must run on macOS because it links AppKit and ScreenCaptureKit." >&2
    exit 2
fi
if [[ "$APP" != "$ROOT/dist/macos/TopFade.app" ]]; then
    echo "Refusing to replace an unexpected app path: $APP" >&2
    exit 3
fi

echo "[TopFade] Building the native macOS target ($CONFIGURATION)..."
swift build \
    --package-path "$PACKAGE_ROOT" \
    --configuration "$CONFIGURATION" \
    -Xswiftc -warnings-as-errors
BIN_ROOT="$(
    swift build \
        --package-path "$PACKAGE_ROOT" \
        --configuration "$CONFIGURATION" \
        --show-bin-path
)"
SOURCE_BIN="$BIN_ROOT/TopFadeMac"
if [[ ! -x "$SOURCE_BIN" ]]; then
    echo "Built executable was not found: $SOURCE_BIN" >&2
    exit 4
fi

STAGE="$OUTPUT_ROOT/.TopFade.app.stage.$$"
# iconutil requires the input directory name to end in ".iconset".
# The prior ".iconset.$PID" suffix was rejected as an invalid iconset.
ICONSET="$OUTPUT_ROOT/.TopFade.$.iconset"
cleanup() {
    rm -rf "$STAGE" "$ICONSET"
}
trap cleanup EXIT
rm -rf "$STAGE" "$ICONSET"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$ICONSET"

install -m 755 "$SOURCE_BIN" "$STAGE/Contents/MacOS/TopFade"
install -m 644 "$PACKAGE_ROOT/Resources/Info.plist" "$STAGE/Contents/Info.plist"

ICON_SOURCE="$ROOT/assets/topfade-1024.png"
if [[ ! -f "$ICON_SOURCE" ]]; then
    echo "Icon source was not found: $ICON_SOURCE" >&2
    exit 5
fi
while read -r pixels name; do
    sips -s format png -z "$pixels" "$pixels" "$ICON_SOURCE" \
        --out "$ICONSET/$name" >/dev/null
done <<'ICONS'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
ICONS
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/TopFade.icns"

plutil -lint "$STAGE/Contents/Info.plist" >/dev/null
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$STAGE"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$STAGE"
fi
codesign --verify --deep --strict "$STAGE"

mkdir -p "$OUTPUT_ROOT"
rm -rf "$APP"
mv "$STAGE" "$APP"

EXECUTABLE="$APP/Contents/MacOS/TopFade"
BYTES="$(stat -f '%z' "$EXECUTABLE")"
SHA256="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
SWIFT_VERSION="$(swift --version | head -n 1 | sed 's/"/\\"/g')"
BUILT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat >"$OUTPUT_ROOT/build-receipt.json" <<EOF
{
  "product": "TopFade",
  "platform": "macOS",
  "configuration": "$CONFIGURATION",
  "built_utc": "$BUILT_UTC",
  "app_bundle": "$APP",
  "executable_bytes": $BYTES,
  "executable_sha256": "$SHA256",
  "architectures": "$ARCHITECTURES",
  "swift": "$SWIFT_VERSION",
  "codesign_identity": "$SIGN_IDENTITY"
}
EOF

echo "[TopFade] App bundle: $APP"
echo "[TopFade] Architecture: $ARCHITECTURES"
echo "[TopFade] Executable: $BYTES bytes"
echo "[TopFade] SHA-256: $SHA256"
