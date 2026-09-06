#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_DIR="$PROJECT_ROOT/dist/drem.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
ASSET_DIR="$PROJECT_ROOT/.build/DremAssets"

cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources" "$ASSET_DIR"
swiftc "$PROJECT_ROOT/Sources/DremBrand/DremMark.swift" \
    "$PROJECT_ROOT/scripts/IconRenderer.swift" -o "$ASSET_DIR/icon-renderer"
"$ASSET_DIR/icon-renderer" "$ASSET_DIR"
iconutil -c icns "$ASSET_DIR/Drem.iconset" -o "$CONTENTS_DIR/Resources/Drem.icns"
cp "$ASSET_DIR/AppIcon.png" "$PROJECT_ROOT/Resources/AppIcon.png"
cp "$ASSET_DIR/DremLogo.png" "$PROJECT_ROOT/Resources/DremLogo.png"
cp "$BIN_DIR/Drem" "$MACOS_DIR/Drem"
cp "$BIN_DIR/drem-hook" "$MACOS_DIR/drem-hook"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
