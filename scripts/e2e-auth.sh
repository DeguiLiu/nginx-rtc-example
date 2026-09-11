#!/usr/bin/env bash
# e2e-auth.sh - assert the signaling/ingest authorization matrix.
#
# Every entry point into this stack takes an HMAC token, and each one is checked
# against a secret chosen by what the token is FOR: play tokens verify against
# <app>/<stream>|play (which the player pages ship, so it is public), publish
# tokens against <app>/<stream>|publish (server-only). A regression here is
# silent in the worst direction -- an entry point that stops checking looks
# exactly like one that works -- so each rule is asserted from both sides.
#
# The assertions are deliberately end-to-end: the checks live in Lua, which the
# host unit tests do not link, and the C handlers behind them are only reachable
# through nginx's own request pipeline.
#
# Session-free by construction: the play requests carry a deliberately unusable
# SDP, so "authorization passed" shows up as 400 (the SDP was rejected) rather
# than 200. That distinguishes the two without creating a session, and it means
# this guard can run against a live server without disturbing it.
#
# The positive WHIP path (publish token -> 201) is not repeated here; it needs a
# real session, and scripts/e2e-whip-release.sh already covers it.
#
# Usage: scripts/e2e-auth.sh
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PLAY="http://127.0.0.1:18082/rtc/v1/play/"
WHIP="http://127.0.0.1:18082/whip/endpoint"
STATS="http://127.0.0.1:18082/rtc/v1/stats"
STREAM="${STREAM:-test}"

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

secret_for() {  # <purpose> -> the secret stream_keys.lua holds for it
    python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\[\"%s\|%s\"\]\s*=\s*\"([^\"]+)\"" % (re.escape(sys.argv[2]), sys.argv[3]), src)
print(m.group(1) if m else "")
' "$BASE/deploy/nginx/conf/stream_keys.lua" "live/$STREAM" "$1" || true
}

PLAY_KEY="$(secret_for play)"
PUB_KEY="$(secret_for publish)"
[ -n "$PLAY_KEY" ] || fail "no play secret for live/$STREAM in stream_keys.lua"
[ -n "$PUB_KEY" ] || fail "no publish secret for live/$STREAM in stream_keys.lua"

sign_at() {  # <secret> <t> -> the signature for that exact stamp
    python3 -c '
import base64, hashlib, hmac, sys
key, name, t = sys.argv[1], sys.argv[2], sys.argv[3]
sig = base64.urlsafe_b64encode(
    hmac.new(key.encode(), ("%s|t=%s" % (name, t)).encode(), hashlib.sha256
).digest()).decode().rstrip("=")
print(sig)
' "$1" "live/$STREAM" "$2"
}

# Play request with NO sdp field: the C handler rejects that with 400 after
# authorization, so 400 means the token passed and 403 means it did not. Omitting
# the field rather than sending a junk offer keeps this session-free -- the SDP
# parser turned out to accept a nonsense offer and answer 200, which would have
# created a session per assertion. Returns the status only.
play_status() {  # <t> <sign>
    local t="$1" sign="$2"
    python3 - "$STREAM" "$t" "$sign" <<'PY' >/tmp/e2e-auth-body.json
import json, sys
stream, t, sign = sys.argv[1:4]
print(json.dumps({"streamurl": "webrtc://127.0.0.1:18082/live/" + stream,
                  "t": t, "sign": sign}))
PY
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$PLAY" \
        -H 'Content-Type: application/json' --data-binary @/tmp/e2e-auth-body.json
}

whip_status() {  # <query string, may be empty>
    local qs="$1"
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
        "${WHIP}?app=live&stream=${STREAM}${qs:+"&$qs"}" \
        -H 'Content-Type: application/sdp' --data-binary 'v=0 not-a-valid-offer'
}

NOW="$(date +%s)"
FAILED=0

check() {  # <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1 (HTTP $3)"
    else
        echo "FAIL: $1: expected HTTP $2, got $3"
        FAILED=$((FAILED + 1))
    fi
}

# --- 1. play tokens verify against the play secret ------------------------
# 400, not 200: the SDP is junk on purpose, so the token is the only thing that
# can produce a 403 here.
check "play token opens /rtc/v1/play/" 400 \
    "$(play_status "$((NOW + 1800))" "$(sign_at "$PLAY_KEY" "$((NOW + 1800))")")"

# --- 2. a play token must not publish, a publish token must not watch -----
check "play token cannot publish over WHIP" 403 \
    "$(whip_status "t=$((NOW + 1800))&sign=$(sign_at "$PLAY_KEY" "$((NOW + 1800))")")"

check "publish token cannot watch" 403 \
    "$(play_status "$((NOW + 1800))" "$(sign_at "$PUB_KEY" "$((NOW + 1800))")")"

# --- 3. no token at all ---------------------------------------------------
check "WHIP without a token" 403 "$(whip_status "")"

# --- 4. the lifetime bound ------------------------------------------------
# MAX_TOKEN_TTL in conf/config.lua. A token claiming three hours must be refused
# even though its signature is valid: without this bound a holder of the secret
# can stamp one for 2099 and never expire. The test below it proves the bound is
# not so tight that it rejects normal clients, which sign now+3600.
check "token claiming 3h is refused" 403 \
    "$(play_status "$((NOW + 10800))" "$(sign_at "$PLAY_KEY" "$((NOW + 10800))")")"

check "token claiming 30min still works" 400 \
    "$(play_status "$((NOW + 1800))" "$(sign_at "$PLAY_KEY" "$((NOW + 1800))")")"

check "expired token is refused" 403 \
    "$(play_status "$((NOW - 3600))" "$(sign_at "$PLAY_KEY" "$((NOW - 3600))")")"

# --- 5. a wrong signature over a valid stamp ------------------------------
# Mangled rather than signed with the other secret, so this stays a signature
# test even if the two secrets ever become equal.
check "bad signature is refused" 403 \
    "$(play_status "$((NOW + 1800))" "$(sign_at "$PLAY_KEY" "$((NOW + 1800))" | tr 'A-Za-z' 'N-ZA-Mn-za-m')")"

rm -f /tmp/e2e-auth-body.json

if [ "$FAILED" -gt 0 ]; then
    fail "$FAILED assertion(s) failed"
fi
echo "PASS: authorization matrix on live/$STREAM"
