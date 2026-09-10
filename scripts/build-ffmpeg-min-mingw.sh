#!/usr/bin/env bash
# build-ffmpeg-min-mingw.sh - cross-compile a minimal static FFmpeg (AAC-only).
#
# The ngx-rtc audio path only needs AAC decode + swresample + libavutil. The
# MSYS2 full ffmpeg package is a DLL that drags in x264/x265/libaom and dozens
# of other codec DLLs; building a static AAC-only subset makes nginx.exe
# self-contained and drops the runtime DLL surface to opus/srtp/pthread/lua.
#
# Output: PREFIX/lib/{libavcodec,libavutil,libswresample}.a + PREFIX/include
# The resulting tree is consumed by NGX_RTC_THIRD (Linux cross-build uses the
# ".a" suffix and -lm -lpthread because uname reports Linux).
set -euo pipefail

MINGW_PREFIX=${MINGW_PREFIX:-"$HOME/.local/mingw"}
FFMPEG_SRC=${FFMPEG_SRC:-"$(cd "$(dirname "$0")/.." && pwd)/scripts/_cache/ffmpeg"}
PREFIX=${PREFIX:-/tmp/winffmpeg-min}
JOBS=${JOBS:-4}

if [ ! -f "$FFMPEG_SRC/configure" ]; then
    echo "error: FFmpeg source not found at $FFMPEG_SRC (run scripts/fetch-deps.sh first)" >&2
    exit 1
fi

export PATH="/tmp/winbin:$MINGW_PREFIX/usr/bin:/usr/bin:/bin"

cd "$FFMPEG_SRC"
make distclean >/dev/null 2>&1 || true

./configure \
    --arch=x86_64 \
    --target-os=mingw32 \
    --cross-prefix=x86_64-w64-mingw32- \
    --enable-cross-compile \
    --prefix="$PREFIX" \
    --disable-everything \
    --disable-programs \
    --disable-doc \
    --disable-network \
    --disable-autodetect \
    --disable-x86asm \
    --disable-avdevice \
    --disable-avformat \
    --disable-avfilter \
    --disable-swscale \
    --disable-postproc \
    --enable-avcodec \
    --enable-avutil \
    --enable-swresample \
    --enable-decoder=aac \
    --enable-parser=aac \
    --enable-demuxer=aac \
    --enable-protocol=file \
    --enable-static \
    --disable-shared

make -j"$JOBS"
make install

echo "[done] minimal FFmpeg installed under $PREFIX"
echo "  libavcodec.a / libavutil.a / libswresample.a + include/"
