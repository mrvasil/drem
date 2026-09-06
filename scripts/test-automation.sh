#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"

# Standalone Command Line Tools include Swift Testing but SwiftPM does not
# always discover its framework and interop runtime. Full Xcode needs no override.
DEVELOPER_DIR_PATH="$(xcode-select -p)"
TESTING_SUPPORT_DIR="$DEVELOPER_DIR_PATH/Library/Developer"
TEST_FLAGS=(--disable-xctest -Xswiftc -warnings-as-errors)
if [[ -d "$TESTING_SUPPORT_DIR/Frameworks/Testing.framework" ]]; then
    TEST_FLAGS+=(
        -Xswiftc -F -Xswiftc "$TESTING_SUPPORT_DIR/Frameworks"
        -Xlinker -rpath -Xlinker "$TESTING_SUPPORT_DIR/Frameworks"
        -Xlinker -rpath -Xlinker "$TESTING_SUPPORT_DIR/usr/lib"
    )
fi

exec swift test "${TEST_FLAGS[@]}" "$@"
