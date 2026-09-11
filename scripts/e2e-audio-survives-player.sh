#!/usr/bin/env bash
# e2e-audio-survives-player.sh - a viewer leaving must not kill the publisher's audio.
#
# Regression guard for the teardown-scope defect in ngx_rtmp_rtc_release_publish().
# NGX_RTMP_DISCONNECT is fired for *every* RTMP session that ends -- an RTMP
# player, an HTTP-FLV viewer -- and a viewer's app/stream resolve to the same
# name as the publisher's. The handler resolved the source by name alone and
# then destroyed src->audio_ctx, released the publish claim and freed the local
# source, all on a viewer's teardown. The publisher kept sending raw AAC, but
# with no transcoder handle every frame was dropped: audio died for the rest of
# the publish, recoverable only by republishing. Video was untouched, so the
# stream looked healthy from every counter except audio.
#
# The assertion has to be end-to-end. It is not a logic error that a unit test
# can reach: it needs two real RTMP sessions on one name plus a media path that
# reports whether Opus is actually arriving, and the handler lives in the
# nginx-rtmp glue layer, which the host suite does not link.
#
# Sequence: publish -> play (audio must be there) -> open and close an RTMP
# player -> play again (audio must still be there).
#
# Usage: scripts/e2e-audio-survives-player.sh [--stream NAME] [--duration MS]
#
#   --stream NAME    stream under live/ to use (default: test; its key is in
#                    deploy/nginx/conf/stream_keys.lua)
#   --duration MS    receive window per WebRTC play (default: 6000)
#
# Exit: 0 both plays carried audio, 1 a play carried none, 2 setup error.
#
# -e is on, so every command whose failure is expected and inspected captures
# its own status (`cmd || RC=$?`).
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
STATS="http://127.0.0.1:18082/rtc/v1/stats"
RTMP="rtmp://127.0.0.1:1935/live"
STREAM="test"
DURATION=6000

while [ $# -gt 0 ]; do
    case "$1" in
        --stream)   STREAM=$2; shift 2 ;;
        --duration) DURATION=$2; shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "e2e-audio-survives-player: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

fail() { echo "FAIL: $*"; exit 1; }

# --- 0. nginx must be up --------------------------------------------------
if ! curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1; then
    echo "[setup] nginx not answering, starting it"
    "$BASE/run.sh" nginx >/dev/null 2>&1 || fail "cannot start nginx"
    for _ in $(seq 1 20); do
        curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1 || fail "nginx did not answer $STATS within 20s"
fi

key_for() {  # <purpose> -> the secret stream_keys.lua holds for it
    python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\[\"%s\|%s\"\]\s*=\s*\"([^\"]+)\"" % (re.escape(sys.argv[2]), sys.argv[3]), src)
print(m.group(1) if m else "")
' "$BASE/deploy/nginx/conf/stream_keys.lua" "live/$STREAM" "$1" || true
}

# Two credentials, because play and publish are different secrets: the play one
# ships inside the player pages, the ingest one never leaves the server. This
# script does both, so it needs both.
KEY="$(key_for play)"
PUB_KEY="$(key_for publish)"
[ -n "$KEY" ] || fail "no play secret for live/$STREAM in stream_keys.lua"
[ -n "$PUB_KEY" ] || fail "no publish secret for live/$STREAM in stream_keys.lua"

sign_with() {  # <secret> <app/stream> -> "t=..&sign=.."
    python3 -c '
import base64, hashlib, hmac, sys, time
key, name = sys.argv[1], sys.argv[2]
t = str(int(time.time()) + 600)
sig = base64.urlsafe_b64encode(
    hmac.new(key.encode(), ("%s|t=%s" % (name, t)).encode(), hashlib.sha256
).digest()).decode().rstrip("=")
print("t=%s&sign=%s" % (t, sig))
' "$1" "$2"
}

# play_once <label> -> echoes the audio packet count, or fails.
#
# The player's own exit status is 1 whenever ok is false -- which is exactly the
# condition under test -- so stdout is what gets inspected, not the status.
play_once() {
    local label=$1 out pkts
    out="$(timeout $((DURATION / 1000 + 40)) node "$BASE/client/play.mjs" \
             --stream "webrtc://127.0.0.1/live/$STREAM" --key "$KEY" \
             --duration "$DURATION" --json 2>/dev/null || true)"
    [ -n "$out" ] || fail "$label: the player produced no JSON (crashed or timed out)"
    pkts="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["audio"]["packets"])
except Exception:
    print(-1)
')"
    [ "$pkts" != "-1" ] || fail "$label: player JSON has no audio.packets: $out"
    echo "$pkts"
}

QS="$(sign_with "$PUB_KEY" "live/$STREAM")"
PUSH_LOG="$(mktemp)"
PUSH_PID=""
# shellcheck disable=SC2064  # expand PUSH_PID now: it is assigned below
trap 'rm -f "$PUSH_LOG"; [ -n "$PUSH_PID" ] && kill "$PUSH_PID" 2>/dev/null; true' EXIT

# --- 1. publish a stream that carries audio -------------------------------
# Video alone would pass the video half of every check below, which is the
# decoy this defect hides behind, so the source must have both.
ffmpeg -v error -re -f lavfi -i testsrc2=size=320x180:rate=15 \
    -f lavfi -i sine=frequency=440:sample_rate=48000 \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 15 \
    -c:a aac -ar 48000 -ac 1 \
    -f flv "$RTMP/$STREAM?$QS" >"$PUSH_LOG" 2>&1 &
PUSH_PID=$!
sleep 2
kill -0 "$PUSH_PID" 2>/dev/null \
    || { cat "$PUSH_LOG"; fail "publisher exited (RTMP announce rejected?)"; }

# --- 2. the baseline: audio arrives before any viewer has been and gone ---
BEFORE="$(play_once baseline)"
[ "$BEFORE" -gt 0 ] \
    || { cat "$PUSH_LOG"; fail "baseline play carried no audio ($BEFORE packets); the source itself is broken, so this run proves nothing"; }
echo "  baseline: audio packets = $BEFORE"

# --- 3. an RTMP player joins and leaves -----------------------------------
# This is the action under test. -t 2 makes it disconnect while the publisher
# carries on; -f null discards the output so nothing here depends on decode.
timeout 30 ffmpeg -v error -i "$RTMP/$STREAM?$(sign_with "$KEY" "live/$STREAM")" -t 2 -f null - \
    >/dev/null 2>&1 || fail "the RTMP player could not play live/$STREAM"
echo "  an RTMP player joined for 2s and left"

# Give the publisher a few frames to land on the other side of the teardown.
sleep 2

# --- 4. audio must have survived ------------------------------------------
AFTER="$(play_once after-teardown)"
echo "  after teardown: audio packets = $AFTER"

if [ "$AFTER" -le 0 ]; then
    cat "$PUSH_LOG"
    fail "audio stopped after a viewer left: $BEFORE packets before, $AFTER after.
      The publisher is still sending and video still flows, so this is the
      teardown-scope defect, not a dead source."
fi

echo "PASS: publisher audio survived a viewer's teardown ($BEFORE -> $AFTER packets)"
exit 0
