#!/usr/bin/env bash
# setup.sh - one-shot dependency bootstrap: fetch pinned sources, build the
# third-party static libs, then configure + build + install OpenResty with the
# self-written module and nginx-http-flv-module.
#
#   OPENRESTY_PREFIX  install prefix (default build/nginx)
#   NGX_RTC_THIRD     prebuilt third/ tree (skip build-deps.sh recompile)
#   NGX_RTC_MODULE_SRC local module checkout override (skip pinned tag fetch)
#   OPENRESTY_SRC     existing openresty source (skip tarball extract)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$BASE/scripts"

echo "== [1/3] fetch dependencies =="
"$SCRIPTS/fetch-deps.sh"

echo "== [2/3] build third-party static libs =="
"$SCRIPTS/build-deps.sh"

echo "== [3/3] configure + build + install OpenResty =="
OPENRESTY_PREFIX="${OPENRESTY_PREFIX:-$BASE/build/nginx}" \
  "$SCRIPTS/build-openresty.sh"

echo "== setup complete =="
echo "  next:  $BASE/run.sh nginx   (sync deploy conf/html and start it)"
