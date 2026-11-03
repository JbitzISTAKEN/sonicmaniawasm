#!/usr/bin/env bash
#
# Build Sonic Mania (via the RSDKv5 decompilation) to WebAssembly.
#
#   ./build-web.sh            # build
#   ./build-web.sh --clean    # wipe the build dir first
#   ./build-web.sh --serve    # build, then serve on :8000
#
# Requires emsdk on PATH:  source ~/emsdk/emsdk_env.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSDK="$ROOT/dependencies/RSDKv5"
THEORA="$ROOT/third_party/theora-wasm"
BUILD="$ROOT/build-web"
OBJ="$BUILD/obj"
GEN="$BUILD/gameobj"
STAGE=/tmp/gobj_build
NCPU="$( (sysctl -n hw.ncpu 2>/dev/null || nproc) )"

if ! command -v emcc >/dev/null 2>&1; then
    echo "error: emcc not found on PATH."
    echo "       source ~/emsdk/emsdk_env.sh   (or wherever emsdk lives)"
    exit 1
fi

if [[ ! -f "$THEORA/lib/libtheoradec.a" ]]; then
    echo "error: libtheoradec.a not found in $THEORA"
    echo "       run ./build-theora.sh first"
    exit 1
fi

# The mod loader is compiled out. Sonic Mania ships no mods in Data.rsdk and the
# loader only adds size and moving parts. Note: it was originally turned off
# chasing an empty scene list / ENGINESTATE_NONE stall, and that diagnosis was
# wrong -- the real causes were a missing Settings.ini (which gates
# LoadDataPack entirely) and routing file reads through SDL_RWops.
INCS=(
    -I "$RSDK/RSDKv5" -I "$RSDK"
    -I "$ROOT/SonicMania" -I "$ROOT/SonicMania/Objects"
    -I "$RSDK/dependencies/all" -I "$RSDK/dependencies/all/tinyxml2"
    -I "$THEORA/include"
)
DEFS=(-DRSDK_USE_SDL2=1 -DRETRO_USE_MOD_LOADER=0 -DRETRO_STANDALONE=0)

COMPILE=(-sUSE_SDL=2 -sUSE_WEBGL2=1 -sUSE_OGG=1)

LINK=(
    -O3
    -sUSE_SDL=2
    -sUSE_WEBGL2=1 -sMAX_WEBGL_VERSION=2 -sMIN_WEBGL_VERSION=2 -sFULL_ES3
    -sUSE_OGG=1
    "$THEORA/lib/libtheoradec.a"
    # ASYNCIFY is deliberately absent. The frame loop is driven by
    # emscripten_set_main_loop instead (see RetroEngine.cpp), so nothing needs to
    # suspend the stack mid-frame. ASYNCIFY also rewrites every function's wasm
    # signature, which breaks indirect calls through RSDKv5's API function
    # pointer tables ("function signature mismatch" as soon as a menu opens).
    -sALLOW_MEMORY_GROWTH=1 -sFETCH=1
    -sINITIAL_MEMORY=805306368 -sSTACK_SIZE=5242880 -sEXIT_RUNTIME=0
    -sMODULARIZE=1 -sEXPORT_NAME=createRetroEngine -sEXPORT_ES6=1 -sINVOKE_RUN=0
    # miniaudio's Web Audio backend reaches into Module.HEAPF32 directly.
    -sEXPORTED_RUNTIME_METHODS=FS,callMain,HEAPF32,HEAPU8,HEAPU32,HEAP16,HEAP32,HEAPU16
    -sEXPORTED_FUNCTIONS=_main,_malloc,_free,_RSDK_SetBrowserFullscreenState,_RSDK_GetWebWindowState,_RSDK_WebSetWindowSize,_RSDK_WebSetBorder,_RSDK_WebSetVsync,_RSDK_WebSetTripleBuffered,_RSDK_WebResetAutoWindow,_RSDK_WebApplySwapInterval,_RSDK_WebSetKey,_RSDK_WebSetFocus,_RSDK_WebReleaseAllKeys,_RSDK_WebRewindIntro,_RSDK_WebSetAudioMuted,_RSDK_WebSceneLoading
)

case "${1:-}" in --clean) rm -rf "$BUILD" "$STAGE";; esac
mkdir -p "$OBJ" "$GEN" "$STAGE"

echo "==> translating shaders to GLSL ES 3.00"
python3 "$RSDK/platforms/web/tools/translate-glsl.py" | tail -1

echo "==> building engine"
# macOS still ships bash 3.2, which has no mapfile.
ENGINE_SRC=()
while IFS= read -r line; do
    [[ -n "$line" ]] && ENGINE_SRC+=("$line")
done < <(sed -n '24,55p' "$RSDK/CMakeLists.txt" | grep -oE '[A-Za-z0-9_/.]+\.(cpp|c)')
printf '%s\n' "${ENGINE_SRC[@]}" | xargs -P "$NCPU" -I{} bash -c '
    src="$1"
    flat="$(echo "$src" | tr "/" "_")"
    [[ "$src" == *.c ]] && std=() || std=(-std=c++17)
    emcc -c "'"$RSDK"'/$src" -o "'"$OBJ"'/engine_$flat.o" \
        -O3 \
        -I "'"$RSDK"'/RSDKv5" -I "'"$RSDK"'" \
        -I "'"$ROOT"'/SonicMania" \
        -I "'"$RSDK"'/dependencies/all" -I "'"$RSDK"'/dependencies/all/tinyxml2" \
        -I "'"$THEORA"'/include" \
        -DRSDK_USE_SDL2=1 -DRETRO_USE_MOD_LOADER=0 -DRETRO_STANDALONE=0 \
        -sUSE_SDL=2 -sUSE_WEBGL2=1 -sUSE_OGG=1 "${std[@]}" 2>"'"$OBJ"'/engine_$flat.log"
' _ {}
echo "    engine objects: $(ls "$OBJ"/engine_*.o | wc -l | tr -d ' ')"

echo "==> building game objects ($NCPU jobs)"
# All.c is excluded on purpose: it #includes every other object, so compiling
# it alongside them produces hundreds of duplicate symbols at link time.
find "$ROOT/SonicMania/Objects" -name '*.c' ! -name 'All.c' -print0 | xargs -0 -P "$NCPU" -I{} bash -c '
    src="$1"
    emcc -c "$src" -o "/tmp/gobj_build/$(echo "$src" | tr "/" "_" | sed "s/\.c$/.o/")" \
        -O3 \
        -I "'"$RSDK"'/RSDKv5" -I "'"$RSDK"'" \
        -I "'"$ROOT"'/SonicMania" -I "'"$ROOT"'/SonicMania/Objects" \
        -I "'"$RSDK"'/dependencies/all" -I "'"$RSDK"'/dependencies/all/tinyxml2" \
        -I "'"$THEORA"'/include" \
        -DRSDK_USE_SDL2=1 -DRETRO_USE_MOD_LOADER=0 -DRETRO_STANDALONE=0 \
        -sUSE_SDL=2 -sUSE_WEBGL2=1 -sUSE_OGG=1 2>/dev/null
' _ {}

emcc -c "$ROOT/SonicMania/Game.c" -o "$GEN/Game.o" "${INCS[@]}" "${DEFS[@]}" "${COMPILE[@]}"
cp "$STAGE"/*.o "$GEN/" 2>/dev/null || true
echo "    game objects: $(ls "$GEN"/*.o | wc -l | tr -d ' ')"

echo "==> linking"
# Drop any stale unity object: All.c #includes everything else, so linking it
# alongside the individual objects is hundreds of duplicate symbols.
rm -f "$GEN"/*_All.o "$GEN"/All.o
# em++ (not emcc) so libc++ is linked in. The engine has C++ translation units
# (Reader.cpp, RetroEngine.cpp, ...) and passing only .o files to emcc makes it
# assume a pure-C link, which leaves operator new/std::string undefined.
em++ "$OBJ"/*.o "$GEN"/*.o -o "$BUILD/RetroEngine.js" "${LINK[@]}"

# Assemble the servable directory.
# Stamp a cache-busting id derived from the wasm *and* the shaders, so a rebuilt
# engine or a shader fix can never be masked by a browser's cached
# RetroEngine.js/.wasm/Data/Shaders files.
hash_files() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$@"
    else
        sha256sum "$@"
    fi
}
BUILD_ID="$(hash_files "$BUILD/RetroEngine.wasm" "$RSDK/platforms/web/shell.html" "$RSDK/platforms/web/Settings.ini" "$RSDK/platforms/web/shaders/OGL/"*.vs "$RSDK/platforms/web/shaders/OGL/"*.fs | hash_files | cut -c1-16)"
python3 - "$RSDK/platforms/web/shell.html" "$BUILD/index.html" "$BUILD_ID" <<'PY'
import pathlib, sys
src, dst, bid = sys.argv[1], sys.argv[2], sys.argv[3]
pathlib.Path(dst).write_text(pathlib.Path(src).read_text().replace("__BUILD_ID__", bid))
PY
# Mandatory: without Settings.ini the engine never opens Data.rsdk and sits in
# ENGINESTATE_NONE with a black screen.
cp "$RSDK/platforms/web/Settings.ini" "$BUILD/Settings.ini"
cp "$RSDK/platforms/web/rsdkv5u.ico" "$BUILD/"
mkdir -p "$BUILD/Data/Shaders/OGL"
cp "$RSDK/platforms/web/shaders/OGL/"*.vs "$RSDK/platforms/web/shaders/OGL/"*.fs "$BUILD/Data/Shaders/OGL/"

echo
echo "==> done"
ls -lh "$BUILD/RetroEngine.wasm" "$BUILD/RetroEngine.js" | awk '{print "   ", $9, $5}'
echo
echo "Next:"
echo "    cp /path/to/Data.rsdk '$BUILD/Data.rsdk'    # ~200MB, legally obtained"
echo "    python3 -m http.server --directory '$BUILD' 8000"

if [[ "${1:-}" == "--serve" ]]; then
    python3 -m http.server --directory "$BUILD" 8000
fi