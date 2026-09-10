#!/usr/bin/env bash
# package-linux-src.sh - pack this repo as a Linux source distribution tarball.
#
# The Linux distribution is source-only: the recipient runs scripts/setup.sh
# (fetch-deps -> build-deps -> build-openresty) to compile everything. No
# binaries or third-party source are bundled; see docs/编译文档.md and README.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=${VERSION:-"$(git -C "$BASE" describe --tags --always 2>/dev/null || echo snapshot)"}
NAME="nginx-rtc-example-$VERSION-src"
OUT="$BASE/dist/$NAME.tar.gz"

mkdir -p "$BASE/dist"

tar -czf "$OUT" \
    --exclude='.git' \
    --exclude='build' \
    --exclude='dist' \
    --exclude='scripts/_cache' \
    --exclude='node_modules' \
    --exclude='*.log' \
    -C "$BASE" .

echo "[done] $OUT"
echo "  build on target machine: tar -xzf $NAME.tar.gz && cd $NAME && ./scripts/setup.sh"
