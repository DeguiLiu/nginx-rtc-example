#!/usr/bin/env bash
# build-deps.sh - build the static third-party libs the module links against
# (libopus, libsrtp2, ffmpeg-lite libavcodec/libswresample/libavutil) and install
# them into build/third/{include,lib} - the same layout module/config expects
# ($NGX_RTC_THIRD). opus is built from the vendored source; libsrtp & ffmpeg are
# fetched by fetch-deps.sh.
#
# If you already have a prebuilt third/ tree (libsrtp/opus/ffmpeg .a + headers),
# you do NOT need this step: export NGX_RTC_THIRD=/path/to/that/tree instead.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$BASE/scripts/_cache"
BUILD="$BASE/build"
SRC="$BUILD/src"
THIRD="$BUILD/third"
JOBS=${JOBS:-"$(nproc)"}
mkdir -p "$CACHE" "$SRC" "$THIRD/include" "$THIRD/lib"

echo "== 1/3 opus (vendored source) =="
rm -rf "$SRC/opus"
cp -r "$BASE/vendor/opus-1.3.1" "$SRC/opus"
( cd "$SRC/opus" \
    && ./configure --disable-shared --enable-static --disable-doc --prefix="$THIRD" >/dev/null \
    && make -j"$JOBS" >/dev/null \
    && make install >/dev/null )

echo "== 2/3 libsrtp 2.3.0 (fetched) =="
[ -s "$CACHE/v2.3.0.tar.gz" ] || { echo "run scripts/fetch-deps.sh first"; exit 1; }
rm -rf "$SRC/libsrtp"
mkdir -p "$SRC/libsrtp"
tar -xzf "$CACHE/v2.3.0.tar.gz" -C "$SRC/libsrtp" --strip-components=1
( cd "$SRC/libsrtp" \
    && ./configure --disable-shared --enable-static --prefix="$THIRD" >/dev/null \
    && make -j"$JOBS" >/dev/null \
    && make install >/dev/null )

echo "== 3/3 ffmpeg-lite (fetched, minimal subset) =="
[ -s "$CACHE/ffmpeg-n6.1.tar.gz" ] || { echo "run scripts/fetch-deps.sh first"; exit 1; }
rm -rf "$SRC/ffmpeg"
mkdir -p "$SRC/ffmpeg"
tar -xzf "$CACHE/ffmpeg-n6.1.tar.gz" -C "$SRC/ffmpeg" --strip-components=1
# Minimal subset for the audio worker (AAC decode + resample + alloc).
# If the final nginx link reports missing ffmpeg symbols, re-run with the
# corresponding --enable-* decoder/demuxer added.
( cd "$SRC/ffmpeg" \
    && ./configure --prefix="$THIRD" --disable-everything \
         --enable-static --disable-shared --disable-programs --disable-doc --disable-network \
         --enable-avcodec --enable-avutil --enable-swresample \
         --enable-decoder=aac --enable-decoder=aac_latm --enable-parser=aac \
         >/dev/null \
    && make -j"$JOBS" >/dev/null \
    && make install >/dev/null )

echo "[done] third-party libs -> $THIRD"
ls -la "$THIRD/lib"
