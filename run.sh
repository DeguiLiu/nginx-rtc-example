#!/usr/bin/env bash
# Self-developed WebRTC RTC module: sync deploy config into an nginx prefix,
# then start/stop/push/supervise. No absolute paths hardcoded.
#
#   ./run.sh sync|nginx|start|push|transcode|keep-push|keep-transcode|stop|verify|ngxtop
#
# `start` brings up nginx and detaches both supervisors (push + transcode);
# `stop` tears the whole set down. The individual keep-* commands stay
# available for running a single supervisor in the foreground.
#
# Instance prefix resolution: $OPENRESTY_PREFIX -> build/nginx.
# RTC_CANDIDATE_IP overrides auto-detection of the candidate IP.
#
# -u: an unset variable is a bug, not an empty string. Before, a typo'd name
#     silently expanded to "" and the command ran on a wrong/empty argument.
# -o pipefail: a failing stage in a pipeline used to be masked by the last
#     stage's status -- sign_for() would happily push an empty signature.
set -euo pipefail

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
# Two credentials, matching stream_keys.lua's per-purpose secrets. PUSH_KEY is
# the ingest side (RTMP on_publish, WHIP) and is server-only; PLAY_KEY is what
# the player pages ship and what the ladder's pull, the FLV fallback and
# /rtc/v1/play/ verify against. They must differ -- one shared secret made every
# viewer a potential publisher.
PUSH_KEY="${PUSH_KEY:-push-secret-9f8e7d6c5b4a39281706f5e4d3c2b1a0}"
PLAY_KEY="${PLAY_KEY:-demo-secret-0123456789abcdef0123456789abcdef}"
KEEP_PID=/tmp/rtc_keep_push.pid   # pid of keep-push supervisor, for stop()
KEEP_TC_PID=/tmp/rtc_keep_tc.pid  # pid of keep-transcode supervisor, for stop()

# Multi-resolution ladder (srs-demo parity): source stays untouched, each
# rung is an independent RTMP stream transcoded from the source loopback.
# x264 zerolatency + bf=0 keeps every rung WebRTC-playable (no B frames).
# Format: name:width:height:fps:kbps
RES_LADDER="${RES_LADDER:-1080p:1920:1080:30:4000 720p:1280:720:30:2000 540p:960:540:30:1000 360p:640:360:30:600}"

sign_for() {  # app/stream expiry [key] -> base64url HMAC signature
    # Defaults to the publish secret because every caller that signs for a URL
    # ffmpeg acts on is pushing; the one pull passes PLAY_KEY explicitly.
    local msg="$1" exp="$2" key="${3:-$PUSH_KEY}"
    printf '%s' "$msg|t=${exp}" | openssl dgst -sha256 -hmac "$key" -binary \
        | base64 | tr '+/' '-_' | tr -d '='
}

detect_candidate_ip() {
    if [ -n "${RTC_CANDIDATE_IP:-}" ]; then
        printf '%s' "$RTC_CANDIDATE_IP"
        return 0
    fi
    # Every step below is allowed to come up empty: this function's job is to
    # find the best guess or nothing, and the caller falls back to 127.0.0.1.
    # `|| dev=""` / `|| ip=""` keep a non-zero pipeline status (pipefail) from
    # aborting the caller's assignment under `set -e`, which would turn "no
    # address found" into a hard exit before the fallback ever runs.
    local dev ip
    dev="$(ip route show default 2>/dev/null | awk '{print $5; exit}')" || dev=""
    if [ -n "$dev" ]; then
        ip="$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)" || ip=""
        ip="${ip%%$'\n'*}"   # first address of the device only
        if [ -n "$ip" ]; then
            printf '%s' "$ip"
            return 0
        fi
    fi
    # Last resort: any global IPv4 that is not loopback. grep exits 1 when it
    # matches nothing -- normal here, so `|| true` keeps pipefail from making
    # it fatal.
    ip="$(ip -4 -o addr show scope global 2>/dev/null \
          | awk '{print $4}' | cut -d/ -f1 | grep -v '^127\.' | head -n1 || true)"
    printf '%s' "$ip"
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

# nginx writes its master pid to <prefix>/logs/nginx.pid. Reusing it makes a
# second `start` a no-op instead of dying on "bind() to 0.0.0.0:1935 failed",
# which under `set -e` also aborted the supervisor launches that follow it.
nginx_running() {
    local pid
    [ -f "$ORX/logs/nginx.pid" ] || return 1
    pid="$(cat "$ORX/logs/nginx.pid" 2>/dev/null)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_nginx() {
    local pid
    if nginx_running; then
        pid="$(cat "$ORX/logs/nginx.pid")"
        echo "[skip] nginx already running (pid $pid)"
        return 0
    fi
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

    # -maxrate/-bufsize cap the x264 I-frame burst. Without them this push is
    # pure VBR: an ultrafast I-frame spikes far above the ~2.1 Mbps average and
    # overruns the path -- measured as ~52% loss on the original stream while
    # the CBR-capped transcode rungs on the same link stayed at 0%.
    TZ=Asia/Shanghai ffmpeg -re -f lavfi -i testsrc2=size=640x360:rate=30 \
        -f lavfi -i sine=frequency=1000:sample_rate=48000 \
        -vf "$vf_clk" \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 30 -bf 0 -pix_fmt yuv420p \
        -maxrate 2500k -bufsize 1000k \
        -c:a aac -b:a 64k -ar 48000 \
        -f flv "rtmp://127.0.0.1:1935/live/livestream?t=${exp}&sign=${sign}"
}

# Transcode the source stream into each ladder rung. One ffmpeg, N outputs:
# pulls rtmp://.../live/livestream, rescales+re-encodes each rung, pushes
# rtmp://.../live/livestream_<rung>. Every rung is re-encoded (the source is
# 640x360 in the demo, so even the same-size rung is a normal encode here).
start_transcode() {
    local exp sign
    exp=$(( $(date +%s) + 3600 ))
    sign=$(sign_for "live/livestream" "$exp" "$PLAY_KEY")
    local src_url="rtmp://127.0.0.1:1935/live/livestream?t=${exp}&sign=${sign}"

    local args=(-i "$src_url" -loglevel warning)
    local rung name w h fps kbps tsign turl
    for rung in $RES_LADDER; do
        IFS=: read -r name w h fps kbps <<<"$rung"
        tsign=$(sign_for "live/livestream_${name}" "$exp")
        turl="rtmp://127.0.0.1:1935/live/livestream_${name}?t=${exp}&sign=${tsign}"
        # -g $fps (one keyframe per second, same as the source push) bounds the
        # first-frame wait on a rung switch: the player can never decode a rung
        # before its first IDR, so a 2s GOP would mean up to a 2s black screen.
        args+=(
            -map 0:v:0 -map 0:a:0?
            -vf "fps=${fps},scale=w=${w}:h=${h}:force_original_aspect_ratio=decrease,pad=ceil(iw/2)*2:ceil(ih/2)*2"
            -c:v libx264 -preset ultrafast -tune zerolatency -g $fps -bf 0
            -b:v "${kbps}k" -minrate "${kbps}k" -maxrate "$((kbps * 12 / 10))k" -bufsize "$((kbps / 2))k"
            # nal-hrd=cbr is deliberately absent: x264 only accepts it when
            # maxrate == bitrate, so pairing it with the 1.2x headroom above
            # just printed "CBR HRD requires constant bitrate" at startup and
            # was ignored. The minrate/maxrate/bufsize trio below is what
            # actually holds each rung on target.
            -x264-params "scenecut=0:rc_lookahead=0:ref=1"
            -pix_fmt yuv420p
            -c:a aac -b:a 64k -ar 48000
            -f flv "$turl"
        )
    done

    echo "[transcode] $(echo "$RES_LADDER" | wc -w) rungs -> ${RES_LADDER// /, }"
    ffmpeg "${args[@]}"
}

# `pgrep -x ffmpeg` matches the TRANSCODE ffmpeg too -- `exec -a` rewrites
# argv[0] but not /proc/<pid>/comm -- so keep-push concluded "an ffmpeg is
# alive" and never respawned a dead push. Identify the push by the cmdline of
# an actual ffmpeg process instead.
push_running() {
    local p
    for p in $(pgrep -x ffmpeg); do
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "testsrc2"; then
            return 0
        fi
    done
    return 1
}

keep_push() {
    echo "[keep-push] supervising ffmpeg push (pid $$)"
    echo "$$" > "$KEEP_PID"
    trap 'rm -f "$KEEP_PID"; pkill -x ffmpeg 2>/dev/null || true' EXIT
    while true; do
        if ! push_running; then
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
    # Real-time control-plane access metrics. Parses the custom `rtc` log_format
    # from the generated nginx config so request_time is available for
    # slow-request and per-API QPS reporting. The tool is fetched by
    # scripts/fetch-deps.sh into scripts/_cache/ (no third-party source is kept
    # in this repo); a system-wide ngxtop takes precedence when installed.
    local conf="$ORX/conf/nginx.rtc.conf"
    local log="$ORX/logs/rtc-access.log"
    local nt="$BASE/scripts/_cache/ngxtop"
    local arg have_log=0

    if [ ! -f "$conf" ]; then
        conf="$ORX/conf/nginx.conf"
    fi
    if [ ! -f "$log" ]; then
        echo "no access log at $log (start nginx first)" >&2
        exit 1
    fi

    # ngxtop reads stdin when it gets no access log and stdin is not a tty (a
    # pipe, a redirect, a CI job), which silently reports an empty table. Pin
    # the access log unless the caller picked one.
    for arg in "$@"; do
        case "$arg" in
            -l|--access-log|--access-log=*|-l*) have_log=1 ;;
        esac
    done
    if [ "$have_log" -eq 0 ]; then
        set -- -l "$log" "$@"
    fi

    if type -P ngxtop >/dev/null 2>&1; then
        cd "$ORX"
        exec ngxtop -c "$conf" "$@"
    fi
    if [ ! -d "$nt/ngxtop" ]; then
        echo "ngxtop not found: run scripts/fetch-deps.sh, or pip install ngxtop" >&2
        exit 1
    fi
    cd "$ORX"
    PYTHONPATH="$nt" exec python3 -m ngxtop.ngxtop -c "$conf" "$@"
}

# Supervisors (keep-push / keep-transcode) run detached so `start` can return
# as soon as nginx is up. Each is launched as its own process rather than as a
# backgrounded shell function: `$$` inside a backgrounded function is the
# *parent* shell's pid, so the pidfile would name the launcher and `stop` would
# kill the wrong process.
supervisor_pid() {   # pidfile -> running pid on stdout, empty when not running
    local pid
    [ -f "$1" ] || return 0
    pid="$(cat "$1" 2>/dev/null)" || return 0
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"
    fi
    return 0
}

start_supervisor() {   # name pidfile logfile
    local pid
    pid="$(supervisor_pid "$2")"
    if [ -n "$pid" ]; then
        echo "[skip] $1 already running (pid $pid)"
        return 0
    fi
    # setsid puts the supervisor in its own session. `nohup ... &` alone only
    # ignores SIGHUP: it still shares the caller's process group, so anything
    # that cleans up that group on exit takes the supervisor down with it --
    # and the push and every transcoded rung go with it.
    setsid nohup "$0" "$1" >"$3" 2>&1 < /dev/null &
    echo "[start] $1 detached -> $3"
}

stop_supervisor() {   # name pidfile
    local pid i
    pid="$(supervisor_pid "$2")"
    if [ -z "$pid" ]; then
        rm -f "$2"
        return 0
    fi
    kill "$pid" 2>/dev/null || true
    # Wait for it to actually exit before the caller pkill's ffmpeg: a
    # supervisor that is still looping only sees a missing ffmpeg and respawns
    # one, leaving a publisher alive after `stop` returns.
    for i in {1..25}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    rm -f "$2"
    echo "[stop] $1"
}

stop() {
    stop_supervisor keep-push "$KEEP_PID"
    stop_supervisor keep-transcode "$KEEP_TC_PID"
    pkill -f "rtc-transcode-marker" 2>/dev/null || true
    gen_nginx_conf 2>/dev/null || true
    "$ORX/sbin/nginx" -s stop -p "$ORX" -c conf/nginx.rtc.conf 2>/dev/null || true
    pkill -x ffmpeg 2>/dev/null || true
}

case "${1:-}" in
    sync)    sync_deploy ;;
    nginx)   start_nginx ;;
    start)   start_nginx
             sleep 1
             start_supervisor keep-push "$KEEP_PID" /tmp/rtc_keep_push.log
             start_supervisor keep-transcode "$KEEP_TC_PID" /tmp/rtc_keep_tc.log ;;
    push)    start_push ;;
    transcode) start_transcode ;;
    keep-push) keep_push ;;
    keep-transcode) keep_transcode ;;
    stop)    stop ;;
    verify)  shift; node "$BASE/client/play.mjs" "$@" ;;
    ngxtop)  shift; ngxtop "$@" ;;
    *)
        echo "用法: $0 {sync|nginx|start|push|transcode|keep-push|keep-transcode|stop|verify [play.mjs 参数]|ngxtop [参数]}"
        exit 1 ;;
esac
