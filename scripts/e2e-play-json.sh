#!/usr/bin/env bash
# e2e-play-json.sh - assert that /rtc/v1/play/ returns parseable JSON.
#
# Regression guard for the SDP-answer response sizing bug: the handler sized its
# response buffer from ngx_escape_json(NULL, ...) alone, but that call returns
# the number of *extra* bytes escaping needs, not the escaped length. The buffer
# was therefore short by the whole answer, ngx_escape_json wrote past its end,
# and the pool allocations that followed (including the ngx_buf_t for the
# response body) landed inside the overlapped region. The body then carried raw
# pool bytes -- pointers plus this very response's HTTP header -- so the body
# was neither valid UTF-8 nor valid JSON and the player reported "signaling
# returned non-JSON".
#
# The assertion has to be end-to-end: the defect lives in the nginx glue layer
# (ngx_rtc_http_module.c), which the host unit tests do not link, and it only
# manifests when nginx's real escaper and pool allocator are in play.
#
# Usage: scripts/e2e-play-json.sh
#
# -e is on, so every command whose failure is expected and inspected captures
# its own status (`cmd || RC=$?`).
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
STATS="http://127.0.0.1:18082/rtc/v1/stats"
PLAY="http://127.0.0.1:18082/rtc/v1/play/"
RTMP="rtmp://127.0.0.1:1935/live"
STREAM="${STREAM:-playjson}"

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

KEY="$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\[\"%s\"\]\s*=\s*\"([^\"]+)\"" % re.escape(sys.argv[2]), src)
print(m.group(1) if m else "")
' "$BASE/deploy/nginx/conf/stream_keys.lua" "live/$STREAM" || true)"
[ -n "$KEY" ] || fail "no stream key for live/$STREAM in stream_keys.lua"

sign_for() {  # app/stream -> "t=..&sign=.."
    python3 -c '
import base64, hashlib, hmac, sys, time
key, name = sys.argv[1], sys.argv[2]
t = str(int(time.time()) + 600)
sig = base64.urlsafe_b64encode(
    hmac.new(key.encode(), ("%s|t=%s" % (name, t)).encode(), hashlib.sha256
).digest()).decode().rstrip("=")
print("t=%s&sign=%s" % (t, sig))
' "$KEY" "live/$STREAM"
}

# --- 1. a live source, so the answer is a real one ------------------------
# An RTMP publish only enters the cross-worker shm registry once something
# creates the source, so "publishing" in /rtc/v1/stats is not a readiness
# signal here. Keep the publisher up and let the play retry loop below decide.
QS="$(sign_for)"
PUSH_LOG="$(mktemp)"
RESP="$(mktemp)"
REQ="$(mktemp)"
PUSH_PID=""
# shellcheck disable=SC2064  # expand PUSH_PID now: it is assigned below
trap 'rm -f "$PUSH_LOG" "$RESP" "$REQ"; [ -n "$PUSH_PID" ] && kill "$PUSH_PID" 2>/dev/null; true' EXIT

ffmpeg -v error -re -f lavfi -i testsrc2=size=320x180:rate=15 \
    -c:v libx264 -preset ultrafast -tune zerolatency -g 15 \
    -f flv "$RTMP/$STREAM?$QS" >"$PUSH_LOG" 2>&1 &
PUSH_PID=$!
sleep 2
kill -0 "$PUSH_PID" 2>/dev/null || { cat "$PUSH_LOG"; fail "publisher exited (RTMP announce rejected?)"; }

# --- 2. POST a real offer, then require an intact answer ------------------
# Retried because the first frames may not have reached the bridge yet; a
# non-zero signaling code means "no source", not a framing defect.
ATTEMPT=0
LAST=""
while [ "$ATTEMPT" -lt 10 ]; do
    ATTEMPT=$((ATTEMPT + 1))

    python3 - "$STREAM" "$(sign_for)" >"$REQ" <<'PY'
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
PY

    CODE="$(curl -s -o "$RESP" -w '%{http_code}' --max-time 5 -X POST "$PLAY" \
        -H 'Content-Type: application/json' --data-binary @"$REQ" || true)"
    [ "$CODE" = "200" ] || fail "play signaling returned HTTP $CODE"

    LAST="$(python3 - "$RESP" <<'PY' || true
import json, sys
raw = open(sys.argv[1], "rb").read()
def verdict(kind, detail):
    print(kind)
    print(detail)
    raise SystemExit
try:
    text = raw.decode("utf-8")
except UnicodeDecodeError as e:
    verdict("FRAMING", "body is not valid UTF-8 (%s): %r" % (e, raw[:160]))
try:
    d = json.loads(text)
except json.JSONDecodeError as e:
    verdict("FRAMING", "body is not valid JSON (%s): %r" % (e, raw[:160]))
if d.get("code") != 0:
    verdict("NOTREADY", "code=%r" % d.get("code"))
sdp = d.get("sdp") or ""
for needle in ("v=0", "a=candidate:", "a=setup:", "a=ssrc:"):
    if needle not in sdp:
        verdict("FRAMING", "answer is missing %r in %r" % (needle, sdp[:200]))
verdict("OK", "%d bytes of SDP" % len(sdp))
PY
)"
    KIND="${LAST%%$'\n'*}"
    DETAIL="${LAST#*$'\n'}"
    case "$KIND" in
        OK)       echo "PASS: play answer is valid JSON ($DETAIL)"
                  echo "PASS: /rtc/v1/play/ JSON framing on live/$STREAM"
                  exit 0 ;;
        # A framing defect is the bug under test: report it at once rather than
        # spinning, since retrying cannot turn invalid JSON into valid JSON.
        FRAMING)  fail "$DETAIL" ;;
    esac
    sleep 1
done

cat "$PUSH_LOG" 2>/dev/null || true
fail "no successful answer after $ATTEMPT attempts (last: $DETAIL)"
