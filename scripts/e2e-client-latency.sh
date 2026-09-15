#!/usr/bin/env bash
# e2e-client-latency.sh - assert the viewer-side latency report endpoint.
#
# The end-to-end latency a viewer experiences cannot be measured by the server:
# half of it (jitter buffer, decode, present) happens inside the browser, and
# the only clock that sees both halves is the one that rendered the frame. So
# the player page computes the number and posts it back here, and the server
# joins it against its own per-session stats by ICE ufrag.
#
# That makes this a *client-facing* endpoint -- the one thing in the control
# plane that an untrusted browser writes to. Everything the server turns into a
# shared-dict key, a JSON field or a Prometheus label is therefore validated
# here, and the whole surface is rate limited. This script is the guard for
# that: it asserts the happy path lands, and that every malformed shape is
# rejected instead of being stored.
#
# Usage: scripts/e2e-client-latency.sh
#        PORT=28082 scripts/e2e-client-latency.sh   # an isolated instance
#
# -e is on, so every command whose failure is expected and inspected captures
# its own status (`cmd || RC=$?`).
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-18082}"
REPORT="http://127.0.0.1:${PORT}/rtc/v1/report"
STATS="http://127.0.0.1:${PORT}/rtc/v1/stats"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "PASS: $*"; }

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

post() {  # <json-body> -> "<http-code>\n<body>"
    curl -s -w '\n%{http_code}' --max-time 5 -X POST "$REPORT" \
        -H 'Content-Type: application/json' --data-binary "$1" 2>&1
}

code_of() { printf '%s' "${1##*$'\n'}"; }
body_of() { printf '%s' "${1%$'\n'*}"; }

UFRAG="e2e$(printf '%08x' $$)"      # distinct per run, <= 63 bytes
[ "${#UFRAG}" -le 63 ] || fail "test ufrag too long"
STREAM="live/e2elat"

# --- 1. happy path --------------------------------------------------------
BODY="$(cat <<JSON
{"stream":"$STREAM","ufrag":"$UFRAG","e2e_ms":42.5,"e2e_min":31.0,"frames":120,
 "jb_ms":8.25,"decode_ms":3.5,"rtt_ms":11}
JSON
)"
OUT="$(post "$BODY")"
[ "$(code_of "$OUT")" = "200" ] || fail "valid report rejected: HTTP $(code_of "$OUT") $(body_of "$OUT")"
case "$(body_of "$OUT")" in
    *'"code":0'*) ;;
    *) fail "valid report did not return code 0: $(body_of "$OUT")" ;;
esac
pass "valid report accepted"

# --- 2. it is readable back, with the values it was given ------------------
OUT="$(curl -s --max-time 5 "$REPORT")"
case "$OUT" in
    *"$UFRAG"*) ;;
    *) fail "stored report not visible in GET $REPORT: $OUT" ;;
esac
OUT="$(curl -s --max-time 5 "$REPORT")"
python3 - "$UFRAG" "$STREAM" "$OUT" <<'PY' || fail "stored report has wrong shape (see above)"
import json, sys
ufrag, stream, raw = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.loads(raw)
hit = [r for r in d.get("reports", []) if r.get("ufrag") == ufrag]
if not hit:
    print("  no entry for %s in %r" % (ufrag, raw), file=sys.stderr)
    raise SystemExit(1)
r = hit[0]
if r.get("stream") != stream:
    print("  stream is %r, expected %r" % (r.get("stream"), stream), file=sys.stderr)
    raise SystemExit(1)
for k, want in (("e2e_ms", 42.5), ("e2e_min", 31.0), ("frames", 120),
                ("jb_ms", 8.25), ("decode_ms", 3.5), ("rtt_ms", 11)):
    if abs(float(r.get(k, -1)) - want) > 1e-6:
        print("  %s is %r, expected %r" % (k, r.get(k), want), file=sys.stderr)
        raise SystemExit(1)
PY
pass "stored report round-trips with the values it was posted"

# --- 3. malformed input is refused, not stored ----------------------------
# Each case: a body that must be rejected, and the reason it must be.
reject() {  # <label> <json>
    local label="$1" json="$2" out rc
    # Stay under the endpoint's 2 r/s limit, or the cases start answering 429
    # instead of 400 and stop testing validation at all.
    sleep 0.7
    out="$(post "$json")"
    rc="$(code_of "$out")"
    case "$rc" in
        400|413) pass "rejected $label (HTTP $rc)" ;;
        429) fail "$label hit the rate limit before it could be validated; slow the test down" ;;
        *) fail "$label was accepted: HTTP $rc $(body_of "$out")" ;;
    esac
}

reject "not JSON at all"          'this is not json'
reject "a JSON array"             '[1,2,3]'
reject "missing ufrag"            '{"stream":"'"$STREAM"'","e2e_ms":10}'
reject "empty ufrag"              '{"stream":"'"$STREAM"'","ufrag":"","e2e_ms":10}'
# The ufrag becomes a shared-dict key and a Prometheus label; a quote or a
# newline in it is the one shape that could forge a label set or split a key.
reject "ufrag with a quote"       '{"stream":"'"$STREAM"'","ufrag":"a\"b","e2e_ms":10}'
reject "ufrag with a newline"     '{"stream":"'"$STREAM"'","ufrag":"a\nb","e2e_ms":10}'
reject "ufrag with a colon"       '{"stream":"'"$STREAM"'","ufrag":"a:b","e2e_ms":10}'
reject "ufrag over 63 bytes"      '{"stream":"'"$STREAM"'","ufrag":"'"$(printf 'u%.0s' $(seq 1 64))"'","e2e_ms":10}'
reject "missing e2e_ms"           '{"stream":"'"$STREAM"'","ufrag":"okufrag1","jb_ms":3}'
reject "e2e_ms as a string"       '{"stream":"'"$STREAM"'","ufrag":"okufrag1","e2e_ms":"10"}'
reject "absurdly negative e2e_ms" '{"stream":"'"$STREAM"'","ufrag":"okufrag1","e2e_ms":-5000}'
reject "absurd e2e_ms"            '{"stream":"'"$STREAM"'","ufrag":"okufrag1","e2e_ms":600000}'
reject "missing stream"           '{"ufrag":"okufrag1","e2e_ms":10}'
reject "stream with a quote"      '{"stream":"a\"b","ufrag":"okufrag1","e2e_ms":10}'
reject "stream over 127 bytes"    '{"stream":"'"$(printf 's%.0s' $(seq 1 128))"'","ufrag":"okufrag1","e2e_ms":10}'
reject "non-numeric jb_ms"        '{"stream":"'"$STREAM"'","ufrag":"okufrag1","e2e_ms":10,"jb_ms":"x"}'
reject "negative jb_ms"           '{"stream":"'"$STREAM"'","ufrag":"okufrag1","e2e_ms":10,"jb_ms":-1}'

# A *slightly* negative ingest-to-display is not a malformed report, it is the
# anchor's own quantisation: the server pairs the newest packet's RTP timestamp
# with the moment the report was built, so the mapping carries up to one frame
# interval of negative bias. The page allows -1000ms for exactly that reason,
# and the server has to accept at least the window the page can produce, or the
# numbers quietly stop arriving on the runs where the bias shows.
sleep 0.7
OUT="$(post '{"stream":"'"$STREAM"'","ufrag":"negprobe1","e2e_ms":-14.0,"e2e_min":-14.0,"frames":90}')"
rc="$(code_of "$OUT")"
case "$rc" in
    200) pass "accepted a small negative e2e (anchor bias) (HTTP $rc)" ;;
    429) fail "the negative-e2e case hit the rate limit; slow the test down" ;;
    *) fail "a small negative e2e was rejected: HTTP $rc $(body_of "$OUT")" ;;
esac

# A rejected report must not have created an entry for the ufrag it named.
OUT="$(curl -s --max-time 5 "$REPORT")"
case "$OUT" in
    *okufrag1*) fail "a rejected report was stored anyway (ufrag okufrag1 present)" ;;
    *) pass "rejected reports leave no entry behind" ;;
esac

# --- 4. the endpoint is rate limited --------------------------------------
# The page reports every 5s, so a well-behaved client never gets near this. A
# script or a hostile page that does is what the limit is for.
RL_BODY='{"stream":"'"$STREAM"'","ufrag":"rlprobe1","e2e_ms":10}'
GOT_429=0
for _ in $(seq 1 40); do
    OUT="$(post "$RL_BODY")"
    [ "$(code_of "$OUT")" = "429" ] && { GOT_429=1; break; }
done
[ "$GOT_429" = "1" ] || fail "40 rapid reports were all accepted: no rate limit on the endpoint"
pass "rapid reports are rate limited"

echo "PASS: /rtc/v1/report endpoint contract on $(basename "$REPORT")"
