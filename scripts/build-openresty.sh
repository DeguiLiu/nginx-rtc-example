#!/usr/bin/env bash
# build-openresty.sh - configure + build + install OpenResty with this repo's
# self-written module nginx-rtc-module and nginx-http-flv-module, both fetched
# from pinned git tags by scripts/fetch-deps.sh (no C source lives in this repo).
#
#   prefix:         $OPENRESTY_PREFIX (default build/nginx)
#   openresty src:  $OPENRESTY_SRC (use an existing checkout, no fetch) else
#                   fetch openresty-1.31.1.1 via scripts/fetch-deps.sh
#   module src:     $NGX_RTC_MODULE_SRC (local checkout override, e.g. when
#                   iterating on the module without bumping its pinned tag)
#                   else staged from cache into build/src/nginx-rtc-module
#   third libs:     $NGX_RTC_THIRD (default build/third), produced by
#                   build-deps.sh or an existing prebuilt tree.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$BASE/build"
CACHE="$BASE/scripts/_cache"
ORX="${OPENRESTY_PREFIX:-$BUILD/nginx}"
THIRD="${NGX_RTC_THIRD:-$BUILD/third}"
JOBS=${JOBS:-"$(nproc)"}
mkdir -p "$BUILD/src"

# stage a fetched git dep from cache into build/src (idempotent)
stage_git() { # <name> <marker-file>
    local name marker dst
    name="$1"
    marker="$2"
    dst="$BUILD/src/$name"
    if [ -f "$dst/$marker" ]; then return 0; fi
    [ -d "$CACHE/$name/.git" ] || { echo "run scripts/fetch-deps.sh first ($name)"; exit 1; }
    echo "== $name source: stage from cache =="
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -r "$CACHE/$name"/. "$dst"/
}

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

# --- addon sources: nginx-rtc-module + nginx-http-flv-module ---
if [ -n "${NGX_RTC_MODULE_SRC:-}" ]; then
    MOD="$NGX_RTC_MODULE_SRC"
    echo "== module addon source (env): $MOD =="
else
    MOD="$BUILD/src/nginx-rtc-module"
    stage_git nginx-rtc-module config
fi
HFLV="$BUILD/src/nginx-http-flv-module"
stage_git nginx-http-flv-module config

echo "== configure (prefix=$ORX, third=$THIRD, module=$MOD, http-flv=$HFLV) =="
( cd "$OS" \
    && NGX_RTC_THIRD="$THIRD" ./configure \
        --prefix="$ORX" \
        --with-ld-opt="-Wl,-rpath,$ORX/luajit/lib" \
        --add-module="$MOD" \
        --add-module="$HFLV" )

echo "== make -j$JOBS && make install =="
( cd "$OS" && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "[done] nginx installed under $ORX"
echo "  next:  ./run.sh nginx   (syncs deploy conf/html and starts it)"
