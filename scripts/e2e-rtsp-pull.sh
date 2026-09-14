#!/usr/bin/env bash
# e2e-rtsp-pull.sh - guard the on-demand RTSP pull (deploy/nginx/conf/rtsp_pull.lua).
#
# The RS500 is not on the bench, so the RTSP leg is stubbed: a fake `ffmpeg`
# first on PATH ignores the RTSP input it is handed and publishes a real
# testsrc2 stream to the RTMP URL the manager built. Everything this guard is
# about is then real -- the Lua that decides when to spawn, the ingest token it
# mints from the publish secret, the RTMP -> RTC bridge, and the werift viewer
# whose subscriber count is what keeps the pull alive.
#
# The stub is also what makes "how many pulls are alive" observable: it execs the
# real ffmpeg with a run-unique argv[0] marker, so `pgrep -f` counts pulls and
# nothing else.
#
# The infrared stream is video-only, so the assertions are on the viewer's video
# track. client/play.mjs's own verdict requires audio AND video, so its exit code
# is deliberately not the assertion here.
#
# This script owns the nginx instance for its duration: it stops whatever is
# running, starts the instance itself (the stub has to be on the worker's PATH),
# and stops it again on exit. Idle reclaim alone takes IDLE_SECONDS, so a full
# run is minutes, not seconds.
#
# Usage: scripts/e2e-rtsp-pull.sh   (OPENRESTY_PREFIX selects the nginx prefix)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ORX="${OPENRESTY_PREFIX:-$BASE/build/nginx/nginx}"
STATS="http://127.0.0.1:18082/rtc/v1/stats"
PLAY="http://127.0.0.1:18082/rtc/v1/play/"
STREAM=ir
IDLE_SECONDS=60
RUNID="$$-$(date +%s)"
MARK="rtsp-pull-stub-$RUNID"
RTSP_URL="rtsp://127.0.0.1:6554/$RUNID"
STUB_DIR="$(mktemp -d)"
EMPTY_DIR="$(mktemp -d)"
REQ="$(mktemp)"
RESP="$(mktemp)"
LOG="$ORX/logs/error.log"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "[PASS] $*"; }

cleanup() {
    rm -rf "$STUB_DIR" "$EMPTY_DIR" "$REQ" "$RESP"
    "$BASE/run.sh" stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

[ -x "$ORX/sbin/nginx" ] || fail "no nginx at $ORX/sbin/nginx (set OPENRESTY_PREFIX)"
command -v ffmpeg >/dev/null || fail "ffmpeg not found on PATH"
REAL_FFMPEG="$(command -v ffmpeg)"

# Counts pulls by the marker the stub bakes into its argv[0]: an ffmpeg started
# by anything else (another e2e guard, a demo push) does not match.
pull_pids() { pgrep -f -- "$MARK" 2>/dev/null || true; }
pull_count() { pull_pids | wc -l; }

stats() { curl -fsS --max-time 3 "$STATS" || true; }

wait_for_stats() {
    local i
    for i in $(seq 1 20); do
        curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# "<publishing> <clients>" of live/$STREAM, or "none" when it has no source.
stream_state() {
    stats | python3 -c '
import json, sys
name = "live/" + sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("none")
    raise SystemExit
for s in d.get("streams") or []:
    if s.get("name") == name:
        print("%s %s" % (s.get("publishing"), s.get("clients")))
        raise SystemExit
print("none")
' "$STREAM"
}

wait_for_state() {  # <publishing> <clients> <seconds>
    local want_pub="$1" want_cli="$2" i st
    for i in $(seq 1 "$3"); do
        st="$(stream_state)"
        if [ "$st" != "none" ] && [ "${st% *}" = "$want_pub" ] \
           && [ "${st#* }" = "$want_cli" ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_pull() {  # <seconds>
    local i
    for i in $(seq 1 "$1"); do
        [ "$(pull_count)" -ge 1 ] && return 0
        sleep 1
    done
    return 1
}

# The error log is append-only across runs, so only lines this run added may
# satisfy a grep -- otherwise a previous run's message passes the assertion.
LOG_START=0
log_has() {
    tail -n "+$((LOG_START + 1))" "$LOG" 2>/dev/null | grep -q -- "$1"
}

secret_for() {  # <purpose> -> the secret stream_keys.lua holds for live/$STREAM
    python3 -c '
import re, sys
src = open(sys.argv[1]).read()
pattern = r"\[\"%s\|%s\"\]\s*=\s*\"([^\"]+)\"" % (re.escape(sys.argv[2]), sys.argv[3])
m = re.search(pattern, src)
print(m.group(1) if m else "")
' "$BASE/deploy/nginx/conf/stream_keys.lua" "live/$STREAM" "$1" || true
}

sign_with() {  # <secret> -> "t=..&sign=.." for live/$STREAM
    python3 -c '
import base64, hashlib, hmac, sys, time
key = sys.argv[1]
name = "live/" + sys.argv[2]
t = str(int(time.time()) + 600)
sig = base64.urlsafe_b64encode(
    hmac.new(key.encode(), ("%s|t=%s" % (name, t)).encode(), hashlib.sha256
).digest()).decode().rstrip("=")
print("t=%s&sign=%s" % (t, sig))
' "$1" "$STREAM"
}

post_play() {  # <key> <response outfile> -> prints the HTTP status code
    python3 -c '
import json, sys
stream, qs = sys.argv[1], sys.argv[2]
t = dict(p.split("=", 1) for p in qs.split("&"))
sdp = (
    "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
    "a=group:BUNDLE 0\r\n"
    "m=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\n"
    "a=ice-ufrag:abcd\r\na=ice-pwd:abcdefghijklmnopqrstuvwx\r\n"
    "a=fingerprint:sha-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:"
    "00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF\r\n"
    "a=setup:actpass\r\na=mid:0\r\na=recvonly\r\na=rtpmap:96 H264/90000\r\n"
)
print(json.dumps({
    "streamurl": "webrtc://127.0.0.1:18082/live/" + stream,
    "t": int(t["t"]), "sign": t["sign"], "sdp": sdp,
}))
' "$STREAM" "$(sign_with "$1")" > "$REQ"
    curl -s -o "$2" -w '%{http_code}' --max-time 5 -X POST "$PLAY" \
        -H 'Content-Type: application/json' --data-binary @"$REQ" || true
}

play_once() {  # <duration_ms> <outfile>
    node "$BASE/client/play.mjs" --stream "webrtc://127.0.0.1:18082/live/$STREAM" \
        --key "$PLAY_KEY" --duration "$1" --json >"$2" 2>"$2.err" || true
}

video_pkts() {  # <play.mjs --json output> -> packets received on the video track
    python3 -c '
import json, sys
try:
    lines = open(sys.argv[1]).read().splitlines()
except OSError:
    lines = []
for line in lines:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if isinstance(d.get("video"), dict):
        print(int(d["video"].get("packets", 0)))
        raise SystemExit
print(0)
' "$1"
}

# The player page retries signaling while the pull starts; a bare play.mjs does
# not, so the guard retries the whole run the same way. Every attempt re-registers
# demand, which is also what keeps the pull up between attempts.
play_until_media() {  # <duration_ms> <outfile> <attempts>
    local i pkts
    for i in $(seq 1 "$3"); do
        play_once "$1" "$2"
        pkts="$(video_pkts "$2")"
        if [ "$pkts" -gt 0 ]; then
            echo "[info] viewer attempt $i: video packets=$pkts"
            return 0
        fi
        sleep 1
    done
    return 1
}

write_stub() {
    cat > "$STUB_DIR/ffmpeg" <<STUB
#!/bin/bash
# Stub for scripts/e2e-rtsp-pull.sh: the last argument is the RTMP URL the pull
# manager built, so that is where the test video goes. exec -a keeps a run-unique
# marker in argv[0], which is what the guard counts -- comm stays "ffmpeg", so
# run.sh stop still reaches it. bash, not sh: exec -a is not in POSIX sh, and
# dash exits 127 on it, which reads as "ffmpeg is missing".
last=""
for arg in "\$@"; do last="\$arg"; done
exec -a "$MARK" "$REAL_FFMPEG" -nostdin -v error -re -f lavfi \\
    -i testsrc2=size=320x180:rate=15 -c:v libx264 -preset ultrafast \\
    -tune zerolatency -g 15 -f flv "\$last"
STUB
    chmod +x "$STUB_DIR/ffmpeg"
}

# --- 0. own the instance, with the stub on the workers' PATH ------------------

"$BASE/run.sh" stop >/dev/null 2>&1 || true
write_stub
PLAY_KEY="$(secret_for play)"
PUB_KEY="$(secret_for publish)"
[ -n "$PLAY_KEY" ] || fail "no live/$STREAM play secret in stream_keys.lua"
[ -n "$PUB_KEY" ] || fail "no live/$STREAM publish secret in stream_keys.lua"

echo "[setup] starting nginx with the stub ffmpeg on PATH"
LOG_START=$(wc -l < "$LOG" 2>/dev/null || echo 0)
( cd "$BASE" && PATH="$STUB_DIR:$PATH" RS500_RTSP_URL="$RTSP_URL" \
    OPENRESTY_PREFIX="$ORX" ./run.sh nginx ) >/dev/null || fail "cannot start nginx"
wait_for_stats || fail "nginx did not answer $STATS within 20s"

# --- 1. a rejected play never wakes the pull ---------------------------------

CODE="$(post_play "wrong-$PLAY_KEY" "$RESP")"
[ "$CODE" = "403" ] || fail "bad-signature play returned HTTP $CODE, want 403"
sleep 2
[ "$(pull_count)" -eq 0 ] || fail "bad-signature play started a pull: $(pull_pids)"
pass "a rejected play never wakes the pull"

# --- 2. an idle instance pulls nothing --------------------------------------

sleep 2
[ "$(pull_count)" -eq 0 ] || fail "idle instance started a pull: $(pull_pids)"
[ "$(stream_state)" = "none" ] || fail "idle instance published live/$STREAM"
pass "no viewer, no pull, no source"

# --- 3. an authorized play starts one pull, and media reaches a viewer -------

CODE="$(post_play "$PLAY_KEY" "$RESP")"
[ "$CODE" = "200" ] || fail "authorized play returned HTTP $CODE, want 200"
wait_for_pull 10 || fail "no pull started within 10s of an authorized play"
[ "$(pull_count)" -eq 1 ] || fail "want exactly 1 pull, got $(pull_count)"
wait_for_state 1 0 15 || fail "live/$STREAM never published (state=$(stream_state))"
pass "the first authorized play starts exactly one pull"

play_until_media 3000 "$RESP.play" 8 || fail "a viewer never received video packets"
wait_for_state 1 1 10 || fail "the pull has no subscriber (state=$(stream_state))"
pass "the pulled stream reaches a WebRTC viewer and counts as a subscriber"

# --- 4. concurrent viewers share one pull -----------------------------------

BG_PIDS=()
play_once 12000 "$RESP.a" &
BG_PIDS+=($!)
play_once 9000 "$RESP.b" &
BG_PIDS+=($!)
sleep 5
[ "$(pull_count)" -eq 1 ] || fail "two viewers produced $(pull_count) pulls"
wait "${BG_PIDS[@]}" || true
[ "$(video_pkts "$RESP.a")" -gt 0 ] || fail "the longer viewer received no video"
[ "$(pull_count)" -eq 1 ] || fail "pulls left after the viewers: $(pull_count)"
pass "concurrent viewers share one pull"

# --- 5. an unexpected exit is retried while the stream is still wanted -------

play_once 15000 "$RESP.k" &
KEEP_PID=$!
wait_for_pull 10 || fail "pull did not come back before the kill test"
sleep 2
OLD="$(pull_pids)"
kill -9 $OLD 2>/dev/null || true
sleep 1
# A fresh authorized play is what a newly arriving viewer does; it also covers
# the case where killing the publisher took the older viewer's session with it.
post_play "$PLAY_KEY" "$RESP" >/dev/null
NEW=""
for _ in $(seq 1 15); do
    NEW="$(pull_pids)"
    if [ -n "$NEW" ] && [ "$NEW" != "$OLD" ]; then break; fi
    sleep 1
done
if [ -z "$NEW" ] || [ "$NEW" = "$OLD" ]; then
    fail "no pull respawn after killing $OLD (now: '$(pull_pids)')"
fi
echo "[info] killed pull=$OLD, respawned=$NEW"
wait "$KEEP_PID" || true
pass "an unexpected exit is retried"

# --- 6. the pull stops once nobody watches ----------------------------------

echo "[info] waiting out the idle window (${IDLE_SECONDS}s + demand TTL)"
STOPPED=0
for _ in $(seq 1 $((IDLE_SECONDS + 45))); do
    if [ "$(pull_count)" -eq 0 ]; then STOPPED=1; break; fi
    sleep 1
done
[ "$STOPPED" -eq 1 ] || fail "pull alive after the idle window: $(pull_pids)"
ST="$(stream_state)"
if [ "$ST" != "none" ] && [ "${ST% *}" != "0" ]; then
    fail "live/$STREAM still publishing after idle reclaim (state=$ST)"
fi
log_has "rtsp_pull: no viewer for ${IDLE_SECONDS}s, stopping pid=" \
    || fail "no idle-stop line in $LOG"
pass "the pull stops when nobody watches, and says so in the log"

# --- 7. run.sh stop leaves no pull behind -----------------------------------

post_play "$PLAY_KEY" "$RESP" >/dev/null
wait_for_pull 10 || fail "pull did not start for the stop test"
"$BASE/run.sh" stop >/dev/null 2>&1 || true
GONE=0
for _ in $(seq 1 10); do
    if [ "$(pull_count)" -eq 0 ]; then GONE=1; break; fi
    sleep 1
done
[ "$GONE" -eq 1 ] || fail "pull $(pull_pids) survived run.sh stop"
log_has "rtsp_pull: worker exiting, stopping pid=" \
    || fail "no worker-exit line in $LOG (the exit hook did not run)"
pass "run.sh stop takes the pull down with the worker"

# --- 8. a missing ffmpeg fails the pull, not the play ------------------------

# run.sh itself needs the usual tools, so the stub directory is prepended to a
# PATH that has them and no ffmpeg (the real one lives in ~/.local/bin, which is
# deliberately absent here).
echo "[setup] restarting nginx with no ffmpeg on PATH"
LOG_START=$(wc -l < "$LOG" 2>/dev/null || echo 0)
( cd "$BASE" && PATH="$EMPTY_DIR:/usr/bin:/bin" RS500_RTSP_URL="$RTSP_URL" \
    OPENRESTY_PREFIX="$ORX" ./run.sh nginx ) >/dev/null || fail "cannot restart nginx"
wait_for_stats || fail "nginx did not answer $STATS after the restart"
CODE="$(post_play "$PLAY_KEY" "$RESP")"
[ "$CODE" = "200" ] || fail "play with no ffmpeg returned HTTP $CODE, want 200"
sleep 3
wait_for_stats || fail "nginx stopped answering after the failed spawn"
[ "$(pull_count)" -eq 0 ] || fail "a pull appeared without ffmpeg: $(pull_pids)"
log_has "rtsp_pull: spawn failed" || log_has "rtsp_pull: ffmpeg exited" \
    || fail "no spawn-failure line in $LOG"
pass "a missing ffmpeg fails the pull, not the play request"

echo
echo "all steps passed"
