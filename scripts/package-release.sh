#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_DIR="$PROJECT_ROOT/dist/drem.app"
OUTPUT_DIR="$PROJECT_ROOT/dist/release"
EXPECTED_VERSION="${1:-}"

[[ -d "$APP_DIR" ]]
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
if [[ -n "$EXPECTED_VERSION" && "$VERSION" != "$EXPECTED_VERSION" ]]; then
    print -u2 "Tag version $EXPECTED_VERSION does not match bundle version $VERSION"
    exit 1
fi

for binary in Drem drem-hook; do
    ARCHITECTURES="$(lipo -archs "$APP_DIR/Contents/MacOS/$binary")"
    if [[ "$ARCHITECTURES" != "arm64" ]]; then
        print -u2 "$binary must contain only arm64, found: $ARCHITECTURES"
        exit 1
    fi
done

PACKAGE_NAME="drem-$VERSION-macOS-arm64"
ARCHIVE="$OUTPUT_DIR/$PACKAGE_NAME.zip"
CHECKSUMS="$OUTPUT_DIR/SHA256SUMS.txt"
STAGING_ROOT="$(mktemp -d "$PROJECT_ROOT/dist/drem-release.XXXXXX")"
PACKAGE_DIR="$STAGING_ROOT/$PACKAGE_NAME"
VERIFY_DIR="$STAGING_ROOT/verify"
trap 'rm -rf "$STAGING_ROOT"' EXIT

mkdir -p "$PACKAGE_DIR" "$OUTPUT_DIR"
ditto "$APP_DIR" "$PACKAGE_DIR/drem.app"
cp "$PROJECT_ROOT/scripts/install-hooks.py" "$PACKAGE_DIR/install-hooks.py"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$PACKAGE_DIR/"
cat > "$PACKAGE_DIR/README.txt" <<EOF
drem $VERSION ($BUILD) for Apple Silicon

1. Move drem.app to ~/Applications.
2. Open it once with Control-click > Open if macOS asks for confirmation.
3. For reliable Codex and Claude Code lifecycle events, run from this folder:
   python3 install-hooks.py
4. Start drem from ~/Applications.

The app is ad-hoc signed and is not notarized with Apple Developer ID.
Do not disable Gatekeeper globally.

Documentation: https://github.com/mrvasil/drem
EOF

rm -f "$ARCHIVE" "$CHECKSUMS"
ditto -c -k --sequesterRsrc --keepParent "$PACKAGE_DIR" "$ARCHIVE"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "${ARCHIVE:t}" > "${CHECKSUMS:t}"
    shasum -a 256 -c "${CHECKSUMS:t}"
)

mkdir -p "$VERIFY_DIR"
ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
VERIFIED_PACKAGE="$VERIFY_DIR/$PACKAGE_NAME"
VERIFIED_APP="$VERIFIED_PACKAGE/drem.app"

for required in \
    "$VERIFIED_APP" \
    "$VERIFIED_PACKAGE/install-hooks.py" \
    "$VERIFIED_PACKAGE/README.txt" \
    "$VERIFIED_PACKAGE/LICENSE" \
    "$VERIFIED_PACKAGE/THIRD_PARTY_NOTICES.md"; do
    [[ -e "$required" ]]
done

codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"
for binary in Drem drem-hook; do
    VERIFIED_ARCHITECTURES="$(lipo -archs "$VERIFIED_APP/Contents/MacOS/$binary")"
    if [[ "$VERIFIED_ARCHITECTURES" != "arm64" ]]; then
        print -u2 "Archived $binary must contain only arm64, found: $VERIFIED_ARCHITECTURES"
        exit 1
    fi
done

VERIFIED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$VERIFIED_APP/Contents/Info.plist")"
VERIFIED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$VERIFIED_APP/Contents/Info.plist")"
[[ "$VERIFIED_VERSION" == "$VERSION" ]]
[[ "$VERIFIED_BUILD" == "$BUILD" ]]

print "$ARCHIVE"
print "$CHECKSUMS"
