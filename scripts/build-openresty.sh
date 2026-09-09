#!/usr/bin/env bash
# build-openresty.sh - configure + build + install OpenResty with this repo's
# self-written module (module/) and the vendored nginx-http-flv-module.
#
#   ORX/prefix:     $OPENRESTY_PREFIX (default build/nginx)
#   openresty src:  $OPENRESTY_SRC (use an existing checkout, no fetch) else
#                   fetch openresty-1.31.1.1 via scripts/fetch-deps.sh
#   third libs:     module/config reads $NGX_RTC_THIRD (default build/third);
#                   produce it with build-deps.sh or point it at an existing tree.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$BASE/build"
CACHE="$BASE/scripts/_cache"
ORX="${OPENRESTY_PREFIX:-$BUILD/nginx}"
THIRD="${NGX_RTC_THIRD:-$BUILD/third}"
JOBS=${JOBS:-"$(nproc)"}
mkdir -p "$BUILD/src"

# --- openresty source ---
if [ -n "${OPENRESTY_SRC:-}" ]; then
    OS="$OPENRESTY_SRC"
    echo "== openresty source (env): $OS =="
else
    TAR="openresty-1.31.1.1.tar.gz"
    [ -s "$CACHE/$TAR" ] || { echo "run scripts/fetch-deps.sh first"; exit 1; }
    echo "== openresty source: extract $TAR =="
    OS="$BUILD/src/openresty-1.31.1.1"
    rm -rf "$OS"
    tar -xzf "$CACHE/$TAR" -C "$BUILD/src"
fi

[ -d "$THIRD/lib" ] || { echo "third libs missing under $THIRD - run build-deps.sh or set NGX_RTC_THIRD"; exit 1; }

echo "== configure (prefix=$ORX, third=$THIRD) =="
( cd "$OS" \
    && NGX_RTC_THIRD="$THIRD" ./configure \
        --prefix="$ORX" \
        --with-ld-opt="-Wl,-rpath,$ORX/luajit/lib" \
        --add-module="$BASE/module" \
        --add-module="$BASE/vendor/nginx-http-flv-module" )

echo "== make -j$JOBS && make install =="
( cd "$OS" && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "[done] nginx installed under $ORX"
echo "  next:  ./run.sh nginx   (syncs deploy conf/html and starts it)"
