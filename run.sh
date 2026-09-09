#!/usr/bin/env bash
# Self-developed WebRTC RTC module: sync deploy config into an nginx prefix,
# then start/stop/push/supervise. No absolute paths hardcoded.
#
#   ./run.sh sync|nginx|push|keep-push|stop|verify
#
# Instance prefix resolution: $OPENRESTY_PREFIX -> build/nginx.
# RTC_CANDIDATE_IP overrides auto-detection of the candidate IP.
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="$BASE/deploy/nginx"

if [ -n "${OPENRESTY_PREFIX:-}" ]; then
    ORX="$OPENRESTY_PREFIX"
elif [ -d "$BASE/build/nginx" ]; then
    ORX="$BASE/build/nginx/nginx"
else
    echo "nginx prefix not found: set OPENRESTY_PREFIX or run scripts/setup.sh first" >&2
    exit 1
fi

NGX_CONF_SRC="$DEPLOY/conf/nginx.conf"
NGX_CONF_RUN="$ORX/conf/nginx.rtc.conf"
PUSH_KEY="${PUSH_KEY:-demo-secret-0123456789abcdef0123456789abcdef}"
KEEP_PID=/tmp/rtc_keep_push.pid   # pid of keep-push supervisor, for stop()

detect_candidate_ip() {
    if [ -n "${RTC_CANDIDATE_IP:-}" ]; then
        printf '%s' "$RTC_CANDIDATE_IP"
        return 0
    fi
    local dev
    dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$dev" ]; then
        local ip
        ip="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
        if [ -n "$ip" ]; then
            printf '%s' "$ip"
            return 0
        fi
    fi
    ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n1
}

sync_deploy() {
    echo "[sync] nginx.conf + *.lua -> $ORX/conf/"
    echo "[sync] html/*            -> $ORX/html/"
    mkdir -p "$ORX/conf" "$ORX/html"
    cp -f "$NGX_CONF_SRC" "$ORX/conf/nginx.conf"
    cp -f "$DEPLOY/conf/"*.lua "$ORX/conf/"
    cp -f "$DEPLOY/html/"* "$ORX/html/"
}

gen_nginx_conf() {
    local ip
    ip="$(detect_candidate_ip)"
    if [ -z "$ip" ]; then
        ip="127.0.0.1"
    fi
    sed "s|^[[:space:]]*rtc_candidate_ip[[:space:]].*;|        rtc_candidate_ip ${ip};|" \
        "$NGX_CONF_SRC" > "$NGX_CONF_RUN"
    echo "[conf] rtc_candidate_ip=${ip} -> $NGX_CONF_RUN"
}

start_nginx() {
    echo "[start] nginx instance: $ORX (RTMP 1935, HTTP 18082, RTC UDP 8000)"
    sync_deploy
    gen_nginx_conf
    ( cd "$ORX" && ./sbin/nginx -p . -c conf/nginx.rtc.conf )
}

start_push() {
    local exp sign msg
    exp=$(( $(date +%s) + 3600 ))
    msg="live/livestream|t=${exp}"
    sign=$(printf '%s' "$msg" | openssl dgst -sha256 -hmac "$PUSH_KEY" -binary \
            | base64 | tr '+/' '-_' | tr -d '=')
    echo "[start] ffmpeg push -> rtmp://127.0.0.1:1935/live/livestream?t=${exp}&sign=${sign}"

    # Beijing wall clock (HH:MM:SS) burned into the top-left; TZ makes the
    # drawtext %{localtime} expansion resolve to Asia/Shanghai (+8) regardless
    # of host timezone, giving a wall-time reference to eyeball latency.
    local vf_clk="drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf:text='%{localtime\:%T}':x=12:y=10:fontsize=40:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=12"

    TZ=Asia/Shanghai ffmpeg -re -f lavfi -i testsrc2=size=640x360:rate=30 \
        -f lavfi -i sine=frequency=1000:sample_rate=48000 \
        -vf "$vf_clk" \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 60 -bf 0 -pix_fmt yuv420p \
        -c:a aac -b:a 64k -ar 48000 \
        -f flv "rtmp://127.0.0.1:1935/live/livestream?t=${exp}&sign=${sign}"
}

keep_push() {
    echo "[keep-push] supervising ffmpeg push (pid $$)"
    echo "$$" > "$KEEP_PID"
    trap 'rm -f "$KEEP_PID"' EXIT
    while true; do
        if ! pgrep -x ffmpeg >/dev/null; then
            start_push || true
        fi
        sleep 3
    done
}

stop() {
    if [ -f "$KEEP_PID" ]; then
        kill "$(cat "$KEEP_PID")" 2>/dev/null || true
        rm -f "$KEEP_PID"
    fi
    gen_nginx_conf 2>/dev/null || true
    "$ORX/sbin/nginx" -s stop -p "$ORX" -c conf/nginx.rtc.conf 2>/dev/null || true
    pkill -x ffmpeg 2>/dev/null || true
}

case "${1:-}" in
    sync)    sync_deploy ;;
    nginx)   start_nginx ;;
    start)   start_nginx; sleep 1; start_push ;;
    push)    start_push ;;
    keep-push) keep_push ;;
    stop)    stop ;;
    verify)  node "$BASE/client/play.mjs" ;;
    *)
        echo "用法: $0 {sync|nginx|start|push|keep-push|stop|verify}"
        exit 1 ;;
esac
