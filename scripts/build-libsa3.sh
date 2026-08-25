#!/usr/bin/env bash
# Build libsa3 + ggml for iOS and stage the static libs into vendor/.
#
# Usage: ./scripts/build-libsa3.sh [sim|device]   (default: sim)
#
# The Xcode project links whatever is in vendor/lib-<platform>/, so switching targets means
# re-running this. Both platforms can be staged at once; Xcode picks by SDK.
set -euo pipefail

PLATFORM="${1:-sim}"
SA3_SRC="${SA3_SRC:-$HOME/sa3.cpp}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$PLATFORM" in
    sim)    SYSROOT=iphonesimulator ; ARCH=arm64  ; BUILD="$SA3_SRC/build-ios-sim"     ;;
    simx64) SYSROOT=iphonesimulator ; ARCH=x86_64 ; BUILD="$SA3_SRC/build-ios-sim-x64" ;;
    device) SYSROOT=iphoneos        ; ARCH=arm64  ; BUILD="$SA3_SRC/build-ios-dev"     ;;
    *) echo "unknown platform '$PLATFORM' (sim|simx64|device)" >&2; exit 2 ;;
esac

# cmake is not always on PATH here; the repo's pip-installed copy is the one that built ggml.
if ! command -v cmake >/dev/null 2>&1; then
    CMAKE_DIR="$HOME/.cache/sa3-cmake/lib/python3.9/site-packages/cmake/data/bin"
    [ -x "$CMAKE_DIR/cmake" ] && PATH="$CMAKE_DIR:$PATH"
fi

echo "[sa3] configuring $PLATFORM ($SYSROOT/$ARCH) -> $BUILD"
cmake -S "$SA3_SRC" -B "$BUILD" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SYSROOT" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.4 \
    -DSA3_METAL=ON \
    -DCMAKE_BUILD_TYPE=Release > /dev/null

cmake --build "$BUILD" --target sa3_shared -j"$(sysctl -n hw.ncpu)"

DEST="$HERE/vendor/lib-$PLATFORM"
mkdir -p "$DEST"
# ggml splits into several archives; the app links all of them.
find "$BUILD" -name '*.a' -exec cp {} "$DEST/" \;
cp "$SA3_SRC/src/libsa3.h" "$HERE/vendor/include/"

echo "[sa3] staged into vendor/lib-$PLATFORM:"
ls -1 "$DEST"
