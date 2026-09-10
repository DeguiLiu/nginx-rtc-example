#!/usr/bin/env bash
# Self-developed WebRTC RTC module: sync deploy config into an nginx prefix,
# then start/stop/push/supervise. No absolute paths hardcoded.
#
#   ./run.sh sync|nginx|push|transcode|keep-push|stop|verify|ngxtop
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
KEEP_TC_PID=/tmp/rtc_keep_tc.pid  # pid of keep-transcode supervisor, for stop()

# Multi-resolution ladder (srs-demo parity): source stays untouched, each
# rung is an independent RTMP stream transcoded from the source loopback.
# x264 zerolatency + bf=0 keeps every rung WebRTC-playable (no B frames).
# Format: name:width:height:fps:kbps
RES_LADDER="${RES_LADDER:-1080p:1920:1080:30:4000 720p:1280:720:30:2000 540p:960:540:30:1000 360p:640:360:30:600}"

sign_for() {  # app/stream expiry -> base64url HMAC signature
    local msg="$1" exp="$2"
    printf '%s' "$msg|t=${exp}" | openssl dgst -sha256 -hmac "$PUSH_KEY" -binary \
        | base64 | tr '+/' '-_' | tr -d '='
}

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
    mkdir -p "$ORX/conf" "$ORX/html" "$ORX/rec"
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
    msg="live/livestream"
    sign=$(sign_for "$msg" "$exp")
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

# Transcode the source stream into each ladder rung. One ffmpeg, N outputs:
# pulls rtmp://.../live/livestream, rescales+re-encodes each rung, pushes
# rtmp://.../live/livestream_<rung>. The 360p rung of a 640x360 test source is
# passed through (-c:v copy for matching size) so the demo ladder has no
# wasteful identical re-encode at the bottom rung.
start_transcode() {
    local exp sign
    exp=$(( $(date +%s) + 3600 ))
    sign=$(sign_for "live/livestream" "$exp")
    local src_url="rtmp://127.0.0.1:1935/live/livestream?t=${exp}&sign=${sign}"

    local args=(-i "$src_url" -loglevel warning)
    local rung name w h fps kbps tsign turl
    for rung in $RES_LADDER; do
        IFS=: read -r name w h fps kbps <<<"$rung"
        tsign=$(sign_for "live/livestream_${name}" "$exp")
        turl="rtmp://127.0.0.1:1935/live/livestream_${name}?t=${exp}&sign=${tsign}"
        args+=(
            -map 0:v:0 -map 0:a:0?
            -vf "fps=${fps},scale=w=${w}:h=${h}:force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2"
            -c:v libx264 -preset ultrafast -tune zerolatency -g $((fps * 2)) -bf 0
            -b:v "${kbps}k" -minrate "${kbps}k" -maxrate "$((kbps * 12 / 10))k" -bufsize "$((kbps / 2))k"
            -x264-params "nal-hrd=cbr:scenecut=0:rc_lookahead=0:refs=1"
            -pix_fmt yuv420p
            -c:a aac -b:a 64k -ar 48000
            -f flv "$turl"
        )
    done

    echo "[transcode] $(echo "$RES_LADDER" | wc -w) rungs -> ${RES_LADDER// /, }"
    ffmpeg "${args[@]}"
}

keep_push() {
    echo "[keep-push] supervising ffmpeg push (pid $$)"
    echo "$$" > "$KEEP_PID"
    trap 'rm -f "$KEEP_PID"; pkill -x ffmpeg 2>/dev/null || true' EXIT
    while true; do
        if ! pgrep -x ffmpeg >/dev/null; then
            start_push || true
        fi
        sleep 3
    done
}

# Supervisor for the transcode ffmpeg: restarts it if it dies. The transcode
# process runs with argv[0] rewritten to "rtc-transcode-marker" (bash exec -a),
# so pgrep -x ffmpeg does not match it -- keep-push and keep-transcode watch
# disjoint process sets and never resurrect each other's child.
keep_transcode() {
    echo "[keep-transcode] supervising transcode ffmpeg (pid $$)"
    echo "$$" > "$KEEP_TC_PID"
    trap 'rm -f "$KEEP_TC_PID"; pkill -f "rtc-transcode-marker" 2>/dev/null || true' EXIT
    while true; do
        if ! pgrep -f "rtc-transcode-marker" >/dev/null; then
            ( exec -a rtc-transcode-marker "$0" transcode ) || true
        fi
        sleep 3
    done
}

ngxtop() {
    # Real-time control-plane access metrics (references/ngxtop). Parses the
    # custom `rtc` log_format from the generated nginx config so request_time
    # is available for slow-request and per-API QPS reporting.
    local conf="$ORX/conf/nginx.rtc.conf"
    local log="$ORX/logs/rtc-access.log"
    if [ ! -f "$conf" ]; then
        conf="$ORX/conf/nginx.conf"
    fi
    if [ ! -f "$log" ]; then
        echo "no access log at $log (start nginx first)" >&2
        exit 1
    fi
    if type -P ngxtop >/dev/null 2>&1; then
        cd "$ORX"
        exec ngxtop -c "$conf" "$@"
    fi
    local nt="$BASE/vendor/ngxtop"
    if [ ! -d "$nt" ]; then
        nt="/home/dgliu/workspace/webrtc/references/ngxtop"
    fi
    if [ -d "$nt" ]; then
        cd "$ORX"
        PYTHONPATH="$nt" exec python3 -m ngxtop.ngxtop -c "$conf" "$@"
    fi
    echo "ngxtop not found: pip install ngxtop" >&2
    exit 1
}

stop() {
    if [ -f "$KEEP_PID" ]; then
        kill "$(cat "$KEEP_PID")" 2>/dev/null || true
        rm -f "$KEEP_PID"
    fi
    if [ -f "$KEEP_TC_PID" ]; then
        kill "$(cat "$KEEP_TC_PID")" 2>/dev/null || true
        rm -f "$KEEP_TC_PID"
    fi
    pkill -f "rtc-transcode-marker" 2>/dev/null || true
    gen_nginx_conf 2>/dev/null || true
    "$ORX/sbin/nginx" -s stop -p "$ORX" -c conf/nginx.rtc.conf 2>/dev/null || true
    pkill -x ffmpeg 2>/dev/null || true
}

case "${1:-}" in
    sync)    sync_deploy ;;
    nginx)   start_nginx ;;
    start)   start_nginx; sleep 1; start_push ;;
    push)    start_push ;;
    transcode) start_transcode ;;
    keep-push) keep_push ;;
    keep-transcode) keep_transcode ;;
    stop)    stop ;;
    verify)  node "$BASE/client/play.mjs" ;;
    ngxtop)  shift; ngxtop "$@" ;;
    *)
        echo "用法: $0 {sync|nginx|start|push|transcode|keep-push|keep-transcode|stop|verify|ngxtop}"
        exit 1 ;;
esac
