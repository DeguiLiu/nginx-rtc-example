#!/usr/bin/env bash
# fetch-deps.sh - download the tarballs that build-deps.sh / build-openresty.sh
# need, pinned to fixed versions, into scripts/_cache/ (gitignored).
#
# Network notes: GitHub downloads try ghfast.top acceleration first (fall back
# to direct). openresty comes from openresty.org. After download, verify with a
# known SHA-256 where listed.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$BASE/scripts/_cache"
mkdir -p "$CACHE"

ghurl() { # <repo> <ref> <asset>  -> try ghfast then upstream
    local repo="$1" ref="$2" asset="$3" out="$CACHE/$asset"
    if [ -s "$out" ]; then echo "[cache] $asset"; return 0; fi
    echo "[get ] $asset"
    curl -fsSL "https://ghfast.top/https://github.com/${repo}/releases/download/${ref}/${asset}" -o "$out" \
        || curl -fsSL "https://github.com/${repo}/releases/download/${ref}/${asset}" -o "$out"
}

# libsrtp 2.3.0 (ciscosystems)
ghurl cisco/libsrtp v2.3.0 v2.3.0.tar.gz

# OpenResty 1.31.1.1
ORX_TAR="openresty-1.31.1.1.tar.gz"
if [ ! -s "$CACHE/$ORX_TAR" ]; then
    echo "[get ] $ORX_TAR (openresty.org)"
    curl -fsSL "https://openresty.org/download/$ORX_TAR" -o "$CACHE/$ORX_TAR"
fi

# FFmpeg release source (n6.1). Used for the audio worker's
# libavcodec/libswresample/libavutil subset.
ghurl FFmpeg/FFmpeg n6.1 ffmpeg-n6.1.tar.gz

echo "[done] deps cached under $CACHE"
ls -la "$CACHE"
