#!/usr/bin/env bash
# stress-stability.sh - sustained viewer churn, with a verdict read off the server.
#
# Drives client/stress_viewers.mjs against one instance and watches the things a
# stability run is supposed to move: worker crashes, sends into a closed socket,
# sessions that never retire, and resident memory that only grows. The verdict
# is server-side on purpose -- the client can be perfectly happy while a worker
# is dying behind it.
#
# Several node processes run in parallel rather than one: werift does its DTLS
# in JavaScript on a single thread, so one process saturates a core long before
# the nginx side is under any pressure, and the run would measure the client.
# Each shard gets its own non-overlapping port block.
#
# Sampling is by pid file and /metrics, never by pattern: this host runs other
# people's nginx instances, and `pkill -f nginx` would reach them.
#
# Usage: scripts/stress-stability.sh [options]
#   --concurrent N    viewers per shard            (default 8)
#   --shards N        parallel node processes      (default 3)
#   --hold S          seconds each viewer stays    (default 5)
#   --duration S      seconds of churn             (default 60)
#   --reap-wait S     wait after churn for reaps   (default 45)
#   --http-port P     instance HTTP/metrics port   (default 28082)
#   --log PATH        instance error.log
#   --prefix PATH     instance prefix (used to find logs/nginx.pid)
#   --rss-tolerance K percent RSS growth allowed   (default 20)
#
# Exit: 0 pass, 1 a stability check failed, 2 setup problem.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
CONCURRENT=8
SHARDS=3
HOLD=5
DURATION=60
REAP_WAIT=45
HTTP_PORT="${ISO_HTTP_PORT:-28082}"
ISO_PREFIX="${ISO_PREFIX:-$BASE/build/nginx-iso/nginx}"
LOG="$ISO_PREFIX/logs/error.log"
RSS_TOLERANCE=20
PORT_BASE="${STRESS_PORT_BASE:-43000}"

while [ $# -gt 0 ]; do
    case "$1" in
        --concurrent)  CONCURRENT="$2"; shift 2 ;;
        --shards)      SHARDS="$2"; shift 2 ;;
        --hold)        HOLD="$2"; shift 2 ;;
        --duration)    DURATION="$2"; shift 2 ;;
        --reap-wait)   REAP_WAIT="$2"; shift 2 ;;
        --http-port)   HTTP_PORT="$2"; shift 2 ;;
        --log)         LOG="$2"; shift 2 ;;
        --prefix)      ISO_PREFIX="$2"; LOG="$2/logs/error.log"; shift 2 ;;
        --rss-tolerance) RSS_TOLERANCE="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

fail() { echo "[fail] $*" >&2; exit 2; }

PID_FILE="$ISO_PREFIX/logs/nginx.pid"
[ -f "$PID_FILE" ] || fail "no pid file at $PID_FILE (start the instance first)"
MASTER="$(cat "$PID_FILE")"
[ -d "/proc/$MASTER" ] || fail "master $MASTER is not running"
[ -f "$LOG" ] || fail "no error log at $LOG"

WORKERS=()
while IFS= read -r p; do
    if [ -n "$p" ]; then
        WORKERS+=("$p")
    fi
done < <(pgrep -P "$MASTER" || true)
[ "${#WORKERS[@]}" -gt 0 ] || fail "master $MASTER has no worker processes"

# Sum of utime+stime over the workers, in clock ticks (USER_HZ). The master is
# excluded: it never touches media.
cpu_ticks() {
    local total=0 p stat
    for p in "${WORKERS[@]}"; do
        [ -r "/proc/$p/stat" ] || continue
        stat="$(cat "/proc/$p/stat")"
        # Fields 14 and 15, after the comm field, which may itself contain
        # spaces or parentheses -- so cut everything up to the last ')'.
        stat="${stat##*)}"
        # shellcheck disable=SC2086
        set -- $stat
        total=$((total + ${12} + ${13}))
    done
    echo "$total"
}

rss_kb() {
    local total=0 p v
    for p in "${WORKERS[@]}"; do
        [ -r "/proc/$p/status" ] || continue
        v="$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null || echo 0)"
        total=$((total + ${v:-0}))
    done
    echo "$total"
}

sessions() {
    # rtc_sessions is a gauge over the shm session list, emitted per state even
    # at zero. Sum every state: the interesting number is how many sessions
    # exist at all, and a wedged one is as much of a leak as a live one.
    local raw
    raw="$(curl -fsS --max-time 3 "http://127.0.0.1:$HTTP_PORT/metrics" 2>/dev/null || true)"
    [ -n "$raw" ] || { echo "?"; return; }
    echo "$raw" | awk '/^rtc_sessions\{/ {s += $NF} END {printf "%d", s + 0}'
}

log_bytes() { stat -c %s "$LOG" 2>/dev/null || echo 0; }

MARK="$(log_bytes)"
RSS_START="$(rss_kb)"
CPU_START="$(cpu_ticks)"
SESSIONS_START="$(sessions)"

echo "=== stress: ${SHARDS}x${CONCURRENT} viewers, hold ${HOLD}s, ${DURATION}s ==="
echo "master=$MASTER workers=${WORKERS[*]}"
echo "start: rss=${RSS_START}KB cpu=${CPU_START}ticks sessions=${SESSIONS_START}"

SAMPLE_FILE="$(mktemp -t stress-samples.XXXXXX)"
{
    while :; do
        echo "$(date +%s) $(rss_kb) $(sessions) $(cpu_ticks)" >> "$SAMPLE_FILE"
        sleep 2
    done
} &
SAMPLER=$!
trap 'kill "$SAMPLER" 2>/dev/null || true; rm -f "$SAMPLE_FILE"' EXIT

PIDS=()
for ((s = 0; s < SHARDS; s++)); do
    node "$BASE/client/stress_viewers.mjs" \
        --concurrent "$CONCURRENT" \
        --hold "$HOLD" \
        --duration "$DURATION" \
        --port-base "$((PORT_BASE + s * CONCURRENT * 2))" \
        --api "http://127.0.0.1:$HTTP_PORT" \
        --json \
        > "$SAMPLE_FILE.shard$s.out" 2> "$SAMPLE_FILE.shard$s.err" &
    PIDS+=("$!")
done

CLIENT_RC=0
for p in "${PIDS[@]}"; do
    wait "$p" || CLIENT_RC=1
done

kill "$SAMPLER" 2>/dev/null || true
trap - EXIT

echo
echo "=== client side ==="
for ((s = 0; s < SHARDS; s++)); do
    line="$(tail -n 1 "$SAMPLE_FILE.shard$s.out" 2>/dev/null || true)"
    [ -n "$line" ] && echo "$line" || echo "shard $s: no summary (see $SAMPLE_FILE.shard$s.err)"
done

echo
echo "waiting ${REAP_WAIT}s for the idle reaps"
sleep "$REAP_WAIT"

RSS_END="$(rss_kb)"
CPU_END="$(cpu_ticks)"
SESSIONS_END="$(sessions)"

TEXT="$(tail -c +"$((MARK + 1))" "$LOG" 2>/dev/null || true)"
CRASHES="$(printf '%s' "$TEXT" | grep -cE 'got signal [0-9]+|exited with code 139' || true)"
BADFD="$(printf '%s' "$TEXT" | grep -c 'Bad file descriptor' || true)"
REAPS="$(printf '%s' "$TEXT" | grep -c 'idle timeout, closing session' || true)"
ALERTS="$(printf '%s' "$TEXT" | grep -cE '\[alert\]|\[emerg\]' || true)"

PEAK_RSS="$(awk 'BEGIN{m=0} {if ($2 > m) m = $2} END{print m}' "$SAMPLE_FILE" 2>/dev/null || echo 0)"
PEAK_SESSIONS="$(awk 'BEGIN{m=0} {if ($3 != "?" && $3 > m) m = $3} END{print m}' "$SAMPLE_FILE" 2>/dev/null || echo 0)"
RSS_GROWTH=$((RSS_END - RSS_START))
RSS_GROWTH_PCT=0
[ "$RSS_START" -gt 0 ] && RSS_GROWTH_PCT=$((RSS_GROWTH * 100 / RSS_START))
CPU_SPENT=$((CPU_END - CPU_START))
# Converts ticks to a share of one core over the measured wall time.
ELAPSED=$((DURATION + REAP_WAIT))
CPU_PCT_OF_CORE=$((CPU_SPENT * 100 / (ELAPSED * 100)))

echo
echo "=== server over the window ==="
printf 'crashes:            %s\n' "$CRASHES"
printf 'bad-fd sends:       %s\n' "$BADFD"
printf 'idle reaps:         %s\n' "$REAPS"
printf 'alert/emerg lines:  %s\n' "$ALERTS"
printf 'sessions:           %s -> %s (peak %s)\n' "$SESSIONS_START" "$SESSIONS_END" "$PEAK_SESSIONS"
printf 'worker rss:         %sKB -> %sKB (peak %sKB, %+d%%)\n' \
    "$RSS_START" "$RSS_END" "$PEAK_RSS" "$RSS_GROWTH_PCT"
printf 'worker cpu:         %s ticks over %ss (~%s%% of one core)\n' \
    "$CPU_SPENT" "$ELAPSED" "$CPU_PCT_OF_CORE"

VERDICT=0
[ "$CRASHES" -eq 0 ] || { echo "  FAIL: worker crashed"; VERDICT=1; }
[ "$BADFD" -eq 0 ] || { echo "  FAIL: send into a closed socket"; VERDICT=1; }
[ "$ALERTS" -eq 0 ] || { echo "  FAIL: alert/emerg in the log"; VERDICT=1; }
[ "$RSS_GROWTH_PCT" -le "$RSS_TOLERANCE" ] || { echo "  FAIL: rss grew ${RSS_GROWTH_PCT}%"; VERDICT=1; }
if [ "$SESSIONS_END" != "?" ] && [ "$SESSIONS_START" != "?" ]; then
    # After the reaps the instance must be back where it started. A residue
    # means sessions are not retiring, which is the leak this soak is for.
    if [ "$SESSIONS_END" -gt "$SESSIONS_START" ]; then
        echo "  FAIL: $SESSIONS_END sessions left, started at $SESSIONS_START"
        VERDICT=1
    fi
else
    echo "  SKIP: could not read rtc_sessions from /metrics"
fi
[ "$CLIENT_RC" -eq 0 ] || { echo "  WARN: client reported failures (see shard output)"; }

echo
[ "$VERDICT" -eq 0 ] && echo "[PASS] stable under ${SHARDS}x${CONCURRENT} viewer churn" \
                     || echo "[FAIL] stability check failed"
echo "shard output: $SAMPLE_FILE.shard*.{out,err}"
rm -f "$SAMPLE_FILE"
exit "$VERDICT"
