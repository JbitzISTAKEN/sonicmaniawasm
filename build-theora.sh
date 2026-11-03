#!/usr/bin/env bash
#
# Build a wasm32 decoder-only libtheora for the web port.
#
#   ./build-theora.sh
#
# Requires emcc/emconfigure/emmake on PATH. The Emscripten ogg port supplies
# libogg; only the Theora decoder is built (no encoder, no examples).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=1.1.1
SRC="$ROOT/third_party/libtheora-$VERSION"
DEST="$ROOT/third_party/theora-wasm"

if [[ -f "$DEST/lib/libtheoradec.a" ]]; then
    echo "libtheoradec.a already exists in $DEST"
    exit 0
fi

if ! command -v emcc >/dev/null 2>&1 || ! command -v emconfigure >/dev/null 2>&1; then
    echo "error: emcc/emconfigure not found on PATH."
    exit 1
fi

mkdir -p "$ROOT/third_party"
cd "$ROOT/third_party"

if [[ ! -d "$SRC" ]]; then
    if [[ ! -f "libtheora-$VERSION.tar.xz" ]]; then
        echo "==> fetching libtheora $VERSION"
        curl -L --fail -o "libtheora-$VERSION.tar.xz" \
            "https://downloads.xiph.org/releases/theora/libtheora-$VERSION.tar.xz"
    fi
    tar xf "libtheora-$VERSION.tar.xz"
fi

cd "$SRC"
export CFLAGS="-O2 -sUSE_OGG=1"
export LDFLAGS="-sUSE_OGG=1"
export OGG_CFLAGS="-sUSE_OGG=1"
export OGG_LIBS="-sUSE_OGG=1"

echo "==> configuring libtheora (decode only)"
emconfigure ./configure --prefix="$DEST" \
    --disable-shared --enable-static \
    --disable-encode --disable-examples --disable-spec --disable-asm \
    --disable-oggtest --disable-vorbistest

echo "==> building libtheora"
NCPU="$( (sysctl -n hw.ncpu 2>/dev/null || nproc) )"
emmake make -j"$NCPU"
emmake make install

echo "==> done: $DEST/lib/libtheoradec.a"
