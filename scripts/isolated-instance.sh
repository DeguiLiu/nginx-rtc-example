#!/usr/bin/env bash
# isolated-instance.sh - a second nginx prefix, for work that must not disturb
# the one everyone else is using.
#
# build/nginx is shared: another session may be running its e2e tests against
# it, and a crash reproduction or a latency run needs to restart nginx at will.
# This script assembles a private prefix (its own ports, logs and pid file) from
# the binaries already built into the shared one, so nothing has to be rebuilt.
#
#   up              assemble the prefix, start nginx, start a publisher
#   down            stop the publisher and this prefix's nginx, by pid file
#   push [--anchor] (re)start just the publisher; --anchor also captures
#                   ffmpeg's -progress with wall-clock stamps, which is what
#                   latency_probe.mjs needs as its source-side anchor
#
# Nothing here reaches outside the two prefixes: stop is pid-file based, and the
# publisher is matched by an argv[0] marker, because `pkill -x nginx` or
# `pkill -x ffmpeg` would take down other people's instances and captures.
#
# Usage: scripts/isolated-instance.sh up|down|push [--anchor]
#
# Env overrides:
#   SRC_PREFIX      prefix to take the binary from   (default build/nginx/nginx)
#   ISO_PREFIX      the private prefix               (default build/nginx-iso/nginx)
#   ISO_RTMP_PORT   RTMP ingest port                 (default 11935)
#   ISO_HTTP_PORT   HTTP/signaling port              (default 28082)
#   ISO_RTC_PORT    WebRTC UDP port                  (default 18000)
#   ANCHOR_FILE     --anchor output                  (default <prefix>/logs/anchor.txt)
#   PUSH_KEY        publish secret                   (default: the demo secret)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SRC_PREFIX="${SRC_PREFIX:-$BASE/build/nginx/nginx}"
ISO_PREFIX="${ISO_PREFIX:-$BASE/build/nginx-iso/nginx}"
ISO_RTMP_PORT="${ISO_RTMP_PORT:-11935}"
ISO_HTTP_PORT="${ISO_HTTP_PORT:-28082}"
ISO_RTC_PORT="${ISO_RTC_PORT:-18000}"
ANCHOR_FILE="${ANCHOR_FILE:-$ISO_PREFIX/logs/anchor.txt}"
PUSH_KEY="${PUSH_KEY:-push-secret-9f8e7d6c5b4a39281706f5e4d3c2b1a0}"
# argv[0] of the publisher, so cleanup can address ours and nobody else's. The
# pattern is anchored at the start of the command line when matching: a bare
# `pkill -f $MARK` also matches any shell whose command line mentions it, which
# is how a cleanup step ends up killing the shell that runs it.
PUSH_MARK=iso-instance-push

fail() { echo "[fail] $*" >&2; exit 1; }

[ -x "$SRC_PREFIX/sbin/nginx" ] || fail "no nginx at $SRC_PREFIX/sbin/nginx (set SRC_PREFIX)"

# The private prefix points at the shared tree's lualib/luajit instead of
# copying them, and carries its own conf/logs/rec. Only the config is rewritten,
# and only for the ports: everything else stays identical to the shared prefix,
# which is what makes results comparable between the two.
assemble() {
    mkdir -p "$ISO_PREFIX"/{conf,logs,html,rec,sbin}
    ln -sfn "$SRC_PREFIX/lualib" "$ISO_PREFIX/lualib"
    ln -sfn "$SRC_PREFIX/luajit" "$ISO_PREFIX/luajit"
    cp -r "$SRC_PREFIX/html/." "$ISO_PREFIX/html/" 2>/dev/null || true
    cp -f "$SRC_PREFIX/conf/mime.types" "$ISO_PREFIX/conf/" 2>/dev/null || true
    cp -f "$BASE/deploy/nginx/conf/"*.lua "$ISO_PREFIX/conf/"

    sed -e "s|^[[:space:]]*rtc_candidate_ip[[:space:]].*;|        rtc_candidate_ip 127.0.0.1;|" \
        -e "s|listen 1935;|listen ${ISO_RTMP_PORT};|" \
        -e "s|listen 18082;|listen ${ISO_HTTP_PORT};|" \
        -e "s|listen 8000 udp reuseport;|listen ${ISO_RTC_PORT} udp reuseport;|" \
        -e "s|rtc_candidate_port 8000;|rtc_candidate_port ${ISO_RTC_PORT};|" \
        -e "s|127.0.0.1:18082|127.0.0.1:${ISO_HTTP_PORT}|g" \
        "$BASE/deploy/nginx/conf/nginx.conf" > "$ISO_PREFIX/conf/nginx.rtc.conf"

    grep -q "listen ${ISO_RTMP_PORT};" "$ISO_PREFIX/conf/nginx.rtc.conf" \
        || fail "port substitution did not apply; did deploy/nginx/conf/nginx.conf change?"
}

ports_busy() {
    ss -lntu 2>/dev/null | grep -qE ":(${ISO_RTMP_PORT}|${ISO_HTTP_PORT}|${ISO_RTC_PORT})\b"
}

nginx_pid() {
    local f="$ISO_PREFIX/logs/nginx.pid"
    [ -f "$f" ] || return 1
    local pid
    pid="$(cat "$f" 2>/dev/null)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

stop_nginx() {
    local pid
    if pid="$(nginx_pid)"; then
        kill "$pid" 2>/dev/null || true
        sleep 2
    fi
}

stop_push() {
    pkill -f "^${PUSH_MARK}" 2>/dev/null || true
    sleep 1
}

start_push() {  # [anchor]
    local anchored="${1:-}"
    local exp sign url
    exp=$(( $(date +%s) + 3600 ))
    sign=$(printf '%s' "live/livestream|t=${exp}" | openssl dgst -sha256 -hmac "$PUSH_KEY" \
           -binary | base64 | tr '+/' '-_' | tr -d '=')
    url="rtmp://127.0.0.1:${ISO_RTMP_PORT}/live/livestream?t=${exp}&sign=${sign}"

    # -re on both inputs: it is a per-input option, and pacing only the video
    # lets the unpaced sine source race ahead and drag the video with it (see
    # run.sh for the measurement behind this).
    local ffmpeg_args=(-hide_banner -loglevel warning
        -re -f lavfi -i testsrc2=size=640x360:rate=30
        -re -f lavfi -i sine=frequency=1000:sample_rate=48000 -t 3600
        -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -bf 0 -pix_fmt yuv420p
        -maxrate 2500k -bufsize 1000k -c:a aac -b:a 64k -ar 48000)

    if [ -n "$anchored" ]; then
        mkdir -p "$(dirname "$ANCHOR_FILE")"
        rm -f "$ANCHOR_FILE"
        ffmpeg_args+=(-stats_period 0.05 -progress pipe:1)
    fi

    # exec -a puts the marker in argv[0]. The URL is single-quoted inside the
    # bash -c string: the outer quotes expand the variables, the inner ones keep
    # the & from being read as an operator by the child shell. The anchored
    # variant pipes ffmpeg's -progress through a reader that stamps every line
    # with the wall clock it saw, which is the anchor latency_probe.mjs maps
    # media time onto.
    local cmd
    cmd="exec -a $PUSH_MARK ffmpeg $(printf '%q ' "${ffmpeg_args[@]}") -f flv '$url'"
    if [ -n "$anchored" ]; then
        cmd="$cmd 2>/dev/null | while IFS= read -r l; do v=\${EPOCHREALTIME/./}; \
printf '%s %s\n' \"\${v:0:13}\" \"\$l\"; done > '$ANCHOR_FILE'"
    else
        cmd="$cmd >/dev/null 2>&1"
    fi
    setsid nohup bash -c "$cmd" >/dev/null 2>&1 < /dev/null &

    echo "[push] -> $url"$([ -n "$anchored" ] && echo "  (anchor -> $ANCHOR_FILE)")
    sleep 3
}

up() {
    assemble
    ports_busy && fail "ports ${ISO_RTMP_PORT}/${ISO_HTTP_PORT}/${ISO_RTC_PORT} already in use"
    stop_push
    cp -f "$SRC_PREFIX/sbin/nginx" "$ISO_PREFIX/sbin/nginx"
    chmod +x "$ISO_PREFIX/sbin/nginx"
    ( cd "$ISO_PREFIX" && ./sbin/nginx -p . -c conf/nginx.rtc.conf )
    sleep 2
    start_push
    echo "[up] $ISO_PREFIX  (RTMP ${ISO_RTMP_PORT}, HTTP ${ISO_HTTP_PORT}, UDP ${ISO_RTC_PORT})"
    echo "[up] logs: $ISO_PREFIX/logs/error.log"
}

down() {
    stop_push
    stop_nginx
    echo "[down] $ISO_PREFIX stopped"
}

case "${1:-}" in
    up)   up ;;
    down) down ;;
    push)
        shift
        case "${1:-}" in
            --anchor) stop_push; start_push anchored ;;
            "")       stop_push; start_push ;;
            *)        fail "unknown push option: $1" ;;
        esac ;;
    *)    echo "usage: $0 up|down|push [--anchor]" >&2; exit 1 ;;
esac
