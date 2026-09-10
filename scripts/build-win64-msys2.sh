#!/usr/bin/env bash
# build-win64-msys2.sh - build the Windows nginx.exe live service inside MSYS2.
#
# Run this INSIDE an MSYS2 MINGW64 shell on Windows, never on Linux. It follows
# OpenResty's upstream util/build-win32.sh flow (native mingw64 gcc, no
# --crossbuild hack) and injects this repo's two addon modules:
#
#   nginx-rtc-module        RTMP/WHIP -> WebRTC (SRTP over UDP)
#   nginx-http-flv-module   RTMP core the bridge links against
#
# FFmpeg is cross-built as a minimal AAC-only shared library (the pacman full
# ffmpeg drags in x264/x265/libaom and dozens of codec DLLs). opus/libsrtp stay
# as pacman DLL import libs. The three are merged into a mixed third-party tree
# and exposed to the addon as NGX_RTC_THIRD. OpenSSL/PCRE2/zlib are built from
# source by OpenResty, exactly like the upstream Windows build.
#
# Usage (inside MINGW64):
#   ./scripts/build-win64-msys2.sh
#
# Optional overrides:
#   JOBS=8                 parallel make jobs (default: NUMBER_OF_PROCESSORS)
#   NGX_RTC_MODULE_SRC=... local module checkout override
set -euo pipefail

if [ "${MSYSTEM:-}" != "MINGW64" ]; then
    echo "error: run this inside the MSYS2 MINGW64 shell (MSYSTEM=$MSYSTEM)" >&2
    exit 1
fi

BASE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$BASE/build-win64"
SRC="$BUILD/src"
OUT="$BUILD/openresty-win64"
JOBS=${JOBS:-"${NUMBER_OF_PROCESSORS:-8}"}

ORX_VER=1.31.1.1
ORX="openresty-$ORX_VER"
PCRE=pcre2-10.47
ZLIB=zlib-1.3.2
OPENSSL=openssl-3.5.6
FFMPEG_VER=n8.0
# The win32-compat branch carries the MinGW .dll.a / winpthread config fix; the
# released v0.3.0 tag predates it. Override with NGX_RTC_MODULE_SRC for a local
# checkout while iterating.
MOD_VER=win32-compat
HFLV_VER=v1.2.14

mkdir -p "$SRC"

echo "== [1/8] install mingw64 toolchain + rtc third-party libs =="
pacman -S --needed --noconfirm \
    mingw-w64-x86_64-toolchain \
    base-devel \
    perl \
    mingw-w64-x86_64-opus \
    mingw-w64-x86_64-libsrtp \
    wget git unzip tar

echo "== [2/8] download OpenResty + static dep sources =="
cd "$SRC"
[ -s "$ORX.tar.gz" ] || wget -O "$ORX.tar.gz" \
    "https://openresty.org/download/$ORX.tar.gz"
[ -s "$OPENSSL.tar.gz" ] || wget -O "$OPENSSL.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/$OPENSSL/$OPENSSL.tar.gz"
[ -s "$ZLIB.tar.gz" ] || wget -O "$ZLIB.tar.gz" \
    "https://zlib.net/$ZLIB.tar.gz"
[ -s "$PCRE.tar.gz" ] || wget -O "$PCRE.tar.gz" \
    "https://github.com/PCRE2Project/pcre2/releases/download/$PCRE/$PCRE.tar.gz"

[ -d "$ORX" ] || tar -xzf "$ORX.tar.gz"
[ -d "$SRC/FFmpeg/.git" ] || git clone -q --depth 1 --branch "$FFMPEG_VER" \
    https://github.com/FFmpeg/FFmpeg "$SRC/FFmpeg"

echo "== [3/8] clone the two addon modules =="
if [ -n "${NGX_RTC_MODULE_SRC:-}" ]; then
    MOD="$NGX_RTC_MODULE_SRC"
    echo "  nginx-rtc-module: local override $MOD"
else
    MOD="$SRC/nginx-rtc-module"
    [ -d "$MOD/.git" ] || git clone -q --depth 1 --branch "$MOD_VER" \
        https://github.com/DeguiLiu/nginx-rtc-module "$MOD"
fi
HFLV="$SRC/nginx-http-flv-module"
[ -d "$HFLV/.git" ] || git clone -q --depth 1 --branch "$HFLV_VER" \
    https://github.com/winshining/nginx-http-flv-module "$HFLV"

echo "== [4/8] patch http-flv int8_t guard for MinGW =="
sed -i 's/#if (NGX_WIN32)/#if (NGX_WIN32 \&\& defined(_MSC_VER))/' \
    "$HFLV/ngx_rtmp.h"

echo "== [5/8] build minimal AAC-only FFmpeg (shared) =="
FFMIN="$BUILD/ffmpeg-min"
( cd "$SRC/FFmpeg" \
    && ./configure --prefix="$FFMIN" \
        --disable-everything --disable-programs --disable-doc \
        --disable-network --disable-autodetect --disable-x86asm \
        --disable-avdevice --disable-avformat --disable-avfilter \
        --disable-swscale --disable-postproc \
        --enable-avcodec --enable-avutil --enable-swresample \
        --enable-decoder=aac --enable-parser=aac --enable-demuxer=aac \
        --enable-protocol=file \
        --enable-shared --disable-static \
    && make -j"$JOBS" \
    && make install )

echo "== [6/8] assemble mixed third-party tree =="
THIRD="$BUILD/third"
rm -rf "$THIRD"
mkdir -p "$THIRD/lib" "$THIRD/include"
cp "$FFMIN/lib/"*.dll.a "$THIRD/lib/"
cp /mingw64/lib/libopus.dll.a /mingw64/lib/libsrtp2.dll.a "$THIRD/lib/"
cp -r "$FFMIN/include/"* "$THIRD/include/"
cp -r /mingw64/include/opus /mingw64/include/srtp2 "$THIRD/include/"

echo "== [7/8] extract static deps + configure =="
cd "$SRC/$ORX"
rm -rf objs
mkdir -p objs/lib
cd objs/lib
tar -xf "../../../$OPENSSL.tar.gz"
tar -xf "../../../$ZLIB.tar.gz"
tar -xf "../../../$PCRE.tar.gz"
cd "$SRC/$ORX"

(cd "objs/lib/$OPENSSL" \
    && patch -p1 < "../../../patches/openssl-3.5.5-sess_set_get_cb_yield.patch")

NGX_RTC_THIRD="$THIRD" ./configure \
    --with-cc=gcc \
    --prefix="$OUT" \
    --with-cc-opt='-DFD_SETSIZE=1024' \
    --sbin-path=nginx.exe \
    --with-pcre-jit \
    --without-http_rds_json_module \
    --without-http_rds_csv_module \
    --without-lua_rds_parser \
    --with-ipv6 \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-http_v2_module \
    --without-mail_pop3_module \
    --without-mail_imap_module \
    --without-mail_smtp_module \
    --with-http_stub_status_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_secure_link_module \
    --with-http_random_index_module \
    --with-http_gzip_static_module \
    --with-http_sub_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_mp4_module \
    --with-http_gunzip_module \
    --with-select_module \
    --with-luajit-xcflags="-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT" \
    --with-pcre="objs/lib/$PCRE" \
    --with-zlib="objs/lib/$ZLIB" \
    --with-openssl="objs/lib/$OPENSSL" \
    --add-module="$MOD" \
    --add-module="$HFLV" \
    -j"$JOBS"

echo "== [8/8] make && make install =="
make -j"$JOBS"
make install

echo "== stage runtime DLLs (FFmpeg/opus/libsrtp/pthread) =="
# nginx.exe links OpenSSL statically (built from source), but the pacman media
# libs are DLL import libs, so collect their transitive runtime DLLs from
# /mingw64/bin. Windows system DLLs are absent there and are skipped naturally.
collect_dlls() {
    local exe="$1"
    objdump -p "$exe" 2>/dev/null \
        | sed -n 's/.*DLL Name: \(.*\)/\1/p' \
        | while read -r dll; do
            local src=""
            [ -f "/mingw64/bin/$dll" ] && src="/mingw64/bin/$dll"
            [ -f "$FFMIN/bin/$dll" ] && src="$FFMIN/bin/$dll"
            if [ -f "$src" ] && [ ! -f "$OUT/$dll" ]; then
                cp "$src" "$OUT/"
                collect_dlls "$src"
            fi
        done
}
collect_dlls "$OUT/nginx.exe"

echo ""
echo "[done] nginx.exe installed under:"
echo "  $OUT"
echo ""
echo "next: copy this repo's deploy/nginx/{conf,html} over $OUT, then run:"
echo "  cd $OUT && ./nginx.exe -p ."
