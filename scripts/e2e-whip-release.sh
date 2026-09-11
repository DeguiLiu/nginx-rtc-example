#!/usr/bin/env bash
# e2e-whip-release.sh - assert that a WHIP publisher which goes away releases
# the shm publish right for its stream name.
#
# Regression guard for the cross-worker leak: the media worker that owns the
# UDP/DTLS connection is the one that closes the session, so its per-process
# source must carry NGX_RTC_PUBLISHER_WHIP (tagged in ngx_rtc_stream_attach_from_shm)
# or the release branch is unreachable and the name stays claimed forever.
#
# The assertion is deliberately end-to-end: a single-worker deployment hides the
# bug (the signaling worker tags its own source), and the release path is
# unreachable from the host unit tests (nginx registry functions are stubbed).
#
# Usage: scripts/e2e-whip-release.sh
#
# -e is on, so every command whose failure is *expected and inspected* below has
# to capture its own status (`cmd || RC=$?`). A bare `cmd` followed by `RC=$?`
# would abort the script on exactly the failures this guard exists to report.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
STATS="http://127.0.0.1:18082/rtc/v1/stats"
RTMP="rtmp://127.0.0.1:1935/live"
READY_TIMEOUT_S=30   # rtc_ready_timeout default; the reaper bound
SLACK_S=8

# Stream names this script may claim, all present in deploy stream_keys.lua.
CANDIDATES=(hotreload luahotload whiptest)

fail() { echo "FAIL: $*"; exit 1; }

# --- 0. nginx must be up (start it if it is not) --------------------------
if ! curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1; then
    echo "[setup] nginx not answering, starting it"
    "$BASE/run.sh" nginx >/dev/null 2>&1 || fail "cannot start nginx"
    # Poll instead of sleeping a fixed 2s: on a cold or loaded machine nginx can
    # take longer, and a too-early first probe would be misread as "absent".
    for _ in $(seq 1 20); do
        curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS --max-time 2 "$STATS" >/dev/null 2>&1 || fail "nginx did not answer $STATS within 20s"
fi

stats_get() { curl -fsS --max-time 3 "$STATS"; }

# pub_state <stream> -> "pub=.. clients=.." or "absent"
pub_state() {
    # `|| true`: the stats endpoint can be briefly unavailable (reload, busy
    # worker). That is not a script failure -- the caller treats anything it
    # cannot read as "not free" and keeps polling. Without it, pipefail plus
    # `set -e` would abort the whole run on the first hiccup.
    # The stream name goes through argv, not string interpolation into the
    # Python source, so a name containing a quote cannot break out.
    stats_get | python3 -c '
import sys, json
name = "live/" + sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("parse-error"); raise SystemExit
for s in d.get("streams", []):
    if s["name"] == name:
        print("pub=%d clients=%d" % (s["publishing"], s["clients"]))
        break
else:
    print("absent")
' "$1" || true
}

# --- 1. claim a free stream name -----------------------------------------
STREAM=""
for c in "${CANDIDATES[@]}"; do
    st="$(pub_state "$c")"
    if [ "$st" = "absent" ] || [ "$st" = "pub=0 clients=0" ]; then
        STREAM="$c"
        break
    fi
done
[ -n "$STREAM" ] || fail "no free stream among: ${CANDIDATES[*]}"
echo "[setup] using live/$STREAM"

# --- 1b. this stream's ingest token --------------------------------------
# Ingests authenticate with the publish secret, which is a different secret from
# the one the player pages carry (deploy/nginx/conf/stream_keys.lua). Both WHIP
# and RTMP below push, so both use this one token: sign =
# base64url(HMAC-SHA256(publish_secret, "<app>/<stream>|t=<t>")).
secret_for() {  # <appstream> <purpose> -> secret from stream_keys.lua
    python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\[\"%s\|%s\"\]\s*=\s*\"([^\"]+)\"" % (re.escape(sys.argv[2]), sys.argv[3]), src)
print(m.group(1) if m else "")
' "$BASE/deploy/nginx/conf/stream_keys.lua" "$1" "$2" || true
}

PUB_KEY="$(secret_for "live/$STREAM" publish)"
[ -n "$PUB_KEY" ] || fail "no publish secret for live/$STREAM in stream_keys.lua"

QS="$(python3 -c '
import base64, hashlib, hmac, sys, time
key, name = sys.argv[1], sys.argv[2]
t = str(int(time.time()) + 300)
sig = base64.urlsafe_b64encode(
    hmac.new(key.encode(), ("%s|t=%s" % (name, t)).encode(), hashlib.sha256
).digest()).decode().rstrip("=")
print("t=%s&sign=%s" % (t, sig))
' "$PUB_KEY" "live/$STREAM" || true)"
[ -n "$QS" ] || fail "could not build the ingest token for live/$STREAM"

# --- 2. one short WHIP publish, then let the client go away ---------------
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
# Bounded: whip_push.mjs has no fetch timeout of its own, so a hung signaling
# request used to block this guard forever (and any CI job that runs it).
# `|| RC=$?` keeps `set -e` from aborting before the 409 check below can explain
# the failure.
#
# WHIP_STREAM carries the token because whip_push.mjs splices WHIP_STREAM into
# the endpoint URL verbatim -- APPENDING it here is what lets the client satisfy
# the new access_by_lua_file without that file needing to know about tokens.
RC=0
WHIP_STREAM="$STREAM&$QS" WHIP_DURATION=5000 \
    timeout $((READY_TIMEOUT_S + SLACK_S)) node "$BASE/client/whip_push.mjs" \
    >"$LOG" 2>&1 || RC=$?
[ "$RC" != 124 ] || { cat "$LOG"; fail "whip_push hung: no exit within $((READY_TIMEOUT_S + SLACK_S))s"; }
if grep -q "http=409" "$LOG"; then
    cat "$LOG"
    fail "publish rejected with 409 Conflict (name already claimed)"
fi
[ "$RC" = 0 ] || { cat "$LOG"; fail "whip_push exited $RC"; }
grep -q "DTLS connected" "$LOG" || { cat "$LOG"; fail "publisher never reached DTLS"; }

T0="$(date +%s)"
echo "[push] publisher gone at $(date +%T), waiting for the release"

# --- 3. the publish right must come back (bounded by the reaper) ----------
RELEASED=""
for _ in $(seq 1 $((READY_TIMEOUT_S + SLACK_S))); do
    st="$(pub_state "$STREAM")"
    if [ "$st" = "absent" ] || [ "${st#pub=0}" != "$st" ]; then
        RELEASED=$(( $(date +%s) - T0 ))
        break
    fi
    sleep 1
done
[ -n "$RELEASED" ] || fail "publishing still 1 after $((READY_TIMEOUT_S + SLACK_S))s \
(the media worker's release branch never ran)"

echo "[release] publishing cleared after ${RELEASED}s"

# --- 4. the freed name must accept a different protocol --------------------
# Same token as the WHIP push above: one ingest credential per stream, whichever
# transport carries it.
T1="$(date +%s)"
# `|| RTMP_RC=$?`: a rejected announce is one of the outcomes under test, so it
# must reach the diagnostic below rather than abort the script via `set -e`.
RTMP_RC=0
timeout 20 ffmpeg -v error -re -f lavfi -i testsrc2=size=320x180:rate=15 \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 15 -t 6 \
    -f flv "$RTMP/$STREAM?$QS" >/dev/null 2>&1 || RTMP_RC=$?
RTMP_SECS=$(( $(date +%s) - T1 ))
if [ "$RTMP_RC" != 0 ]; then
    fail "RTMP take-over rejected (rc=$RTMP_RC after ${RTMP_SECS}s): the name was \
still claimed, or the RTMP announce was refused"
fi

echo "[takeover] RTMP ran ${RTMP_SECS}s on live/$STREAM (rc=$RTMP_RC)"

echo "PASS: WHIP release + cross-protocol takeover on live/$STREAM (${RELEASED}s)"
