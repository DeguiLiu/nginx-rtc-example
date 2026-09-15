#!/usr/bin/env bash
# measure-server-cpu.sh - what one connection costs the server, and what an
# abandoned viewer costs until the reaper collects it.
#
# The client is a separate process and its CPU is deliberately not counted: the
# question is what the *server* spends. Both sides run on this box, so the split
# has to be measured rather than argued -- and the only signal available without
# instrumenting nginx is the workers' own CPU time, read from /proc/<pid>/stat.
#
# Three windows, because one number would be misleading:
#
#   idle     streaming with no viewers, the baseline
#   burst    N connects back to back, from which per-connection CPU is derived
#   tail     the window after the burst, when the sessions whose clients left
#            without saying goodbye are still being streamed to -- a viewer that
#            vanishes costs the server until its idle timeout expires, and that
#            shows up here rather than in the burst
#
# Linux only: it reads /proc. Usage: scripts/measure-server-cpu.sh
#
# Env overrides:
#   ISO_PREFIX, ISO_HTTP_PORT   the instance to measure (defaults: the isolated one)
#   RUNS         connects in the burst window            (default 100)
#   SETTLE_SEC   quiet time before measuring anything    (default 45)
#   IDLE_SEC     length of the baseline window           (default 20)
#   TAIL_SEC     length of the post-burst window         (default 40)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ISO_PREFIX="${ISO_PREFIX:-$BASE/build/nginx-iso/nginx}"
ISO_HTTP_PORT="${ISO_HTTP_PORT:-28082}"
RUNS="${RUNS:-100}"
SETTLE_SEC="${SETTLE_SEC:-45}"
IDLE_SEC="${IDLE_SEC:-20}"
TAIL_SEC="${TAIL_SEC:-40}"

fail() { echo "[fail] $*" >&2; exit 1; }

[ -r /proc/self/stat ] || fail "this measurement reads /proc; it is Linux-only"
[ -f "$ISO_PREFIX/logs/nginx.pid" ] || fail "no instance at $ISO_PREFIX (run scripts/isolated-instance.sh up)"
MASTER="$(cat "$ISO_PREFIX/logs/nginx.pid" 2>/dev/null)" || fail "cannot read the pid file"
kill -0 "$MASTER" 2>/dev/null || fail "master $MASTER is not running"

# Only the worker processes: the cache manager idles and would only add noise.
WORKERS="$(for p in $(pgrep -P "$MASTER" 2>/dev/null); do
    if grep -q "worker process" "/proc/$p/cmdline" 2>/dev/null; then
        echo "$p"
    fi
done | tr '\n' ' ')"
[ -n "$WORKERS" ] || fail "no workers under master $MASTER"

HZ="$(getconf CLK_TCK)"
ticks() {
    local total=0 v stat
    for p in $WORKERS; do
        # Fields 14 (utime) and 15 (stime) are counted from after the comm
        # field, which is parenthesised and may itself contain spaces -- nginx's
        # comm is "nginx: worker process", three tokens, so a plain $14 would
        # read two fields short. Cut everything up to the last ')' first.
        stat="$(cat "/proc/$p/stat" 2>/dev/null)" || continue
        stat="${stat##*) }"
        # shellcheck disable=SC2086
        set -- $stat
        v=$(( ${12} + ${13} ))
        total=$((total + v))
    done
    printf '%s' "$total"
}
now_ms() { date +%s%3N; }

echo "prefix:  $ISO_PREFIX"
echo "workers: $WORKERS  (HZ=$HZ)"

echo "settling ${SETTLE_SEC}s so no earlier burst lands in the baseline"
sleep "$SETTLE_SEC"

t0=$(ticks); w0=$(now_ms)
sleep "$IDLE_SEC"
t1=$(ticks); w1=$(now_ms)
idle_ms=$((w1 - w0)); idle_ticks=$((t1 - t0))
idle_rate=$(awk -v t="$idle_ticks" -v ms="$idle_ms" 'BEGIN {printf "%.4f", t * 1000 / ms}')
echo "idle:    ${idle_ticks} ticks over ${idle_ms} ms (${idle_rate} ticks/s)"

t2=$(ticks); w2=$(now_ms)
out="$(cd "$BASE" && timeout 600 node client/connect_probe.mjs \
    --api "http://127.0.0.1:${ISO_HTTP_PORT}" \
    --stream "webrtc://127.0.0.1:${ISO_HTTP_PORT}/live/livestream" \
    --runs "$RUNS" 2>&1)" || true
ok="$(printf '%s' "$out" | grep -c '^run ' || true)"
t3=$(ticks); w3=$(now_ms)
busy_ms=$((w3 - w2)); busy_ticks=$((t3 - t2))

echo "connects: $ok runs, ${busy_ticks} ticks over ${busy_ms} ms"
awk -v bt="$busy_ticks" -v bms="$busy_ms" -v ir="$idle_rate" -v n="$ok" -v hz="$HZ" 'BEGIN {
    idle_here = ir * bms / 1000;
    extra = bt - idle_here;
    printf "idle-equivalent ticks in that window: %.1f\n", idle_here;
    printf "attributable to %d connects: %.1f ticks\n", n, extra;
    if (n > 0) printf "=> server CPU per connect: %.1f ms\n", extra / n * 1000 / hz;
}'

t4=$(ticks); w4=$(now_ms)
sleep "$TAIL_SEC"
t5=$(ticks); w5=$(now_ms)
tail_ms=$((w5 - w4)); tail_ticks=$((t5 - t4))
awk -v tt="$tail_ticks" -v ms="$tail_ms" -v ir="$idle_rate" -v n="$ok" -v hz="$HZ" 'BEGIN {
    printf "\ntail:    %d ticks over %d ms (%.2f ticks/s, idle was %.2f)\n", tt, ms, tt * 1000 / ms, ir;
    if (n > 0 && ms > 0) {
        printf "=> residue per abandoned session over %.0fs: %.1f ms\n", ms / 1000, (tt - ir * ms / 1000) / n * 1000 / hz;
    }
}'
