#!/usr/bin/env bash
# fetch-deps.sh - stage the sources build-deps.sh / build-openresty.sh need,
# pinned to fixed refs, into scripts/_cache/ (gitignored). No source is kept in
# this repo; everything comes from upstream at build time.
#
#   git repos   -> shallow-cloned by tag via gitc()
#   openresty   -> release tarball from openresty.org (not hosted on github)
#
# Network notes:
#   * Hosts where github.com is DNS-hijacked (e.g. /etc/hosts -> Pages CDN) break
#     plain https git to github. Run through a local proxy:
#         export https_proxy=http://127.0.0.1:7890 HTTPS_PROXY=http://127.0.0.1:7890
#     gitc passes http.proxy explicitly (git ignores uppercase HTTPS_PROXY) and
#     curl honours the standard *_PROXY env vars.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$BASE/scripts/_cache"
mkdir -p "$CACHE"

gitc() { # <url> <ref> <name>  -> shallow clone a pinned git ref into cache
    local url="$1" ref="$2"
    local dst="$CACHE/$3"
    if [ -d "$dst/.git" ]; then echo "[cache] $3"; return 0; fi
    echo "[git ] $3 @ $ref"
    local px="${https_proxy:-${HTTPS_PROXY:-}}"
    if [ -n "$px" ]; then
        git clone -q --depth 1 --branch "$ref" -c "http.proxy=$px" "$url" "$dst"
    else
        git clone -q --depth 1 --branch "$ref" "$url" "$dst"
    fi
}

# Self-developed C addon (public MIT) + http-flv (RTMP core the bridge links
# against). Bump refs here when a dependency advances.
gitc https://github.com/DeguiLiu/nginx-rtc-module        v0.4.0 nginx-rtc-module
gitc https://github.com/winshining/nginx-http-flv-module v1.2.14 nginx-http-flv-module

# libsrtp (SRTP) + FFmpeg (aac decode subset) - git tags, no release tarballs
gitc https://github.com/cisco/libsrtp v2.3.0 libsrtp
gitc https://github.com/FFmpeg/FFmpeg n6.1   ffmpeg

# Opus 1.3.1 - the xiph git tree ships only autogen.sh/configure.ac, so use the
# official release tarball (which bundles the generated ./configure).
OPUS_TAR="opus-1.3.1.tar.gz"
if [ ! -s "$CACHE/$OPUS_TAR" ]; then
    echo "[get ] $OPUS_TAR (downloads.xiph.org)"
    curl -fsSL "https://downloads.xiph.org/releases/opus/$OPUS_TAR" -o "$CACHE/$OPUS_TAR"
fi

# OpenResty 1.31.1.1
ORX_TAR="openresty-1.31.1.1.tar.gz"
if [ ! -s "$CACHE/$ORX_TAR" ]; then
    echo "[get ] $ORX_TAR (openresty.org)"
    curl -fsSL "https://openresty.org/download/$ORX_TAR" -o "$CACHE/$ORX_TAR"
fi

echo "[done] deps cached under $CACHE"
ls -la "$CACHE"
