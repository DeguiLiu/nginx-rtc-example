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

# ngxtop - control-plane access-log metrics behind `run.sh ngxtop`. A runtime
# tool, not a build input, so a failure here only warns: nothing in the
# toolchain depends on it. Fetched through pip rather than github (this host
# cannot reach github directly, and 0.0.3 ships as a py2.py3 wheel); --target
# keeps it out of the repo and bundles its deps in the same tree.
if [ ! -d "$CACHE/ngxtop/ngxtop" ]; then
    echo "[pip ] ngxtop 0.0.3 (+ docopt/tabulate/pyparsing)"
    python3 -m pip install --quiet --disable-pip-version-check \
        --target "$CACHE/ngxtop" ngxtop==0.0.3 \
        || python3 -m pip install --quiet --disable-pip-version-check \
               --target "$CACHE/ngxtop" ngxtop \
        || echo "[warn] ngxtop not installed; 'run.sh ngxtop' needs it" >&2
fi

# mediamtx - the RTSP server scripts/e2e-rtsp-pull.sh publishes to, standing in
# for the RS500 device so that guard exercises a real RTSP session instead of a
# stub. A runtime tool, not a build input, so a failure here only warns.
# Pinned by version AND sha256 (the checksum published by the release), fetched
# through the mirror used for github on this host.
MEDIAMTX_VER=v1.21.0
MEDIAMTX_TAR="mediamtx_${MEDIAMTX_VER}_linux_amd64.tar.gz"
MEDIAMTX_SHA=e02e34c3337a35f20ac9e5aa31524566108964e6e37dbc46cf8292169f6c792b
if [ ! -x "$CACHE/mediamtx/mediamtx" ]; then
    echo "[get ] $MEDIAMTX_TAR ($MEDIAMTX_VER)"
    if curl -fsSL "https://ghfast.top/https://github.com/bluenviron/mediamtx/releases/download/$MEDIAMTX_VER/$MEDIAMTX_TAR" \
            -o "$CACHE/$MEDIAMTX_TAR"; then
        if echo "$MEDIAMTX_SHA  $CACHE/$MEDIAMTX_TAR" | sha256sum -c - >/dev/null 2>&1; then
            mkdir -p "$CACHE/mediamtx"
            tar -xzf "$CACHE/$MEDIAMTX_TAR" -C "$CACHE/mediamtx" mediamtx
        else
            echo "[warn] mediamtx sha256 mismatch; e2e-rtsp-pull.sh cannot run" >&2
            rm -f "$CACHE/$MEDIAMTX_TAR"
        fi
    else
        echo "[warn] mediamtx not fetched; e2e-rtsp-pull.sh needs it" >&2
    fi
fi

echo "[done] deps cached under $CACHE"
ls -la "$CACHE"
