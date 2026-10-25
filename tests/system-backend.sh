#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${DEPS:?Set DEPS}"
: "${SDK:?Set SDK}"
FW=$DEPS/Frameworks
OUT=$PWD/build/system-tests
mkdir -p "$OUT"
sh tests/backend.sh
FLAGS="-arch x86_64 -isysroot $SDK -mmacosx-version-min=10.8 -F$FW -ISource -include Cocoa/Cocoa.h -Wno-deprecated-declarations -Wl,-headerpad_max_install_names -Wl,-rpath,/Applications/Adium.app/Contents/Frameworks"
clang $FLAGS Source/ADPService.m Source/ADPAccount.m Source/ADPAccountView.m Source/ADPJoinChatView.m tests/frontend.m \
    -framework Cocoa -framework Adium -framework AIUtilities -o "$OUT/frontend-tests"
sh scripts/normalize-frameworks.sh "$OUT/frontend-tests"
DYLD_FRAMEWORK_PATH="/Applications/Adium.app/Contents/Frameworks:$FW" "$OUT/frontend-tests"
clang $FLAGS tests/client.m -framework Cocoa -framework Adium -framework AIUtilities -o "$OUT/client-tests"
sh scripts/normalize-frameworks.sh "$OUT/client-tests"
ADP_BACKEND_PROFILE="$OUT/profile" ADP_METADATA_PATH="$OUT/protocols.plist" ADP_LOG_PATH="$OUT/client.log" \
    DYLD_FRAMEWORK_PATH="/Applications/Adium.app/Contents/Frameworks:$FW" \
    "$OUT/client-tests" "$PWD/build/DynamicPurple.AdiumLibpurplePlugin"
# A frontend must never link MacPorts or either libpurple implementation.
if otool -L build/DynamicPurple.AdiumLibpurplePlugin/Contents/MacOS/DynamicPurple | tail -n +2 | grep -E '/opt/local|libpurple|AdiumLibpurple'; then
    echo 'FAIL: frontend linked a libpurple runtime' >&2
    exit 1
fi
otool -L build/macports-purple-backend | grep '/opt/local/lib/libpurple'
echo 'PASS: separate frontend/backend linkage'
