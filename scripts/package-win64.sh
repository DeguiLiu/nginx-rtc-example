#!/usr/bin/env bash
# package-win64.sh - assemble the Windows binary distribution zip.
#
# The Windows distribution is binary-only and auth-free (HTTP-FLV over TCP;
# WebRTC/UDP is unavailable on Windows nginx). Point NGINX_DIR at an installed
# nginx prefix produced by build-win64-msys2.sh (MSYS2) or the Linux MinGW
# cross-build, and optionally bundle ffmpeg via FFMPEG_EXE.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
NGINX_DIR="${NGINX_DIR:?set NGINX_DIR to the installed nginx prefix}"
FFMPEG_EXE="${FFMPEG_EXE:-}"
OUT="$BASE/dist/nginx-rtc-win64.zip"
PKG="$BASE/dist/win64-package"

[ -f "$NGINX_DIR/nginx.exe" ] || {
    echo "error: nginx.exe not found under $NGINX_DIR" >&2
    exit 1
}

rm -rf "$PKG"
mkdir -p "$PKG/conf" "$PKG/html" "$PKG/logs"

cp "$NGINX_DIR/nginx.exe" "$PKG/"
for dll in "$NGINX_DIR"/*.dll; do
    [ -f "$dll" ] && cp "$dll" "$PKG/"
done
[ -d "$NGINX_DIR/lua" ] && cp -r "$NGINX_DIR/lua" "$PKG/"
[ -d "$NGINX_DIR/lualib" ] && cp -r "$NGINX_DIR/lualib" "$PKG/"
[ -d "$NGINX_DIR/conf" ] && cp -r "$NGINX_DIR/conf/." "$PKG/conf/"
[ -d "$NGINX_DIR/html" ] && cp -r "$NGINX_DIR/html/." "$PKG/html/"

# Override with the auth-free HTTP-FLV config and the repo play pages/bat files.
cp "$BASE/deploy/win32/nginx-flv.conf" "$PKG/conf/nginx.conf"
cp -r "$BASE/deploy/nginx/html/." "$PKG/html/"
cp "$BASE/deploy/win32/start.bat" \
   "$BASE/deploy/win32/stop.bat" \
   "$BASE/deploy/win32/push_test.bat" \
   "$BASE/deploy/win32/README.md" \
   "$PKG/"

if [ -n "$FFMPEG_EXE" ] && [ -f "$FFMPEG_EXE" ]; then
    mkdir -p "$PKG/tools"
    cp "$FFMPEG_EXE" "$PKG/tools/ffmpeg.exe"
fi

mkdir -p "$BASE/dist"
rm -f "$OUT"
( cd "$BASE/dist" && zip -qr "$OUT" win64-package )

echo "[done] $OUT"
