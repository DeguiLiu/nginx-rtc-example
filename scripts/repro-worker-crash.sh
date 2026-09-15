#!/usr/bin/env bash
# repro-worker-crash.sh - catch a worker SIGSEGV with a real stack.
#
# The module installs its own SIGSEGV handler, but a crash inside the event loop
# leaves it almost nothing to print: `backtrace()` comes back with the handler's
# own frame and the signal trampoline, so the error log says "got signal 11
# addr=0" and nothing else. Cores are no help on this host either -- core_pattern
# pipes to apport, which discards cores for binaries it does not own -- and
# ptrace_scope=1 forbids attaching gdb to a process that is not its child.
#
# So nginx has to be *started* by gdb. One worker is forced for the trace:
# `follow-fork-mode child` trails the first forked worker and detaches the
# master, so with two workers the other one would run untraced and could swallow
# the crash. The cost is that cross-worker behaviour is out of scope for this
# run; the crashes worth chasing have been same-worker.
#
# Usage: scripts/repro-worker-crash.sh [--binary <path>] [--rounds N] [--out <file>]
#
#   --binary <path>   nginx binary to test   (default: the prefix's own, i.e. the
#                     one scripts/isolated-instance.sh installs). Point it at an
#                     older binary to check that this harness still catches what
#                     it is supposed to catch.
#   --rounds N        churn rounds to run    (default 10, env ROUNDS)
#   --out <file>      gdb transcript         (default <prefix>/logs/gdb-crash.txt)
#
# Exit: 0 = the worker crashed and the stack is in --out; 3 = no crash within
# the rounds, which is the expected result for a fixed binary and the reason
# this is not simply "failure".
#
# Env: ISO_PREFIX, ISO_HTTP_PORT, ROUND_SLEEP (default 12 s, to let sessions
# reach their idle timeout between rounds)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
ISO_PREFIX="${ISO_PREFIX:-$BASE/build/nginx-iso/nginx}"
ISO_HTTP_PORT="${ISO_HTTP_PORT:-28082}"
ISO_RTMP_PORT="${ISO_RTMP_PORT:-11935}"
ISO_RTC_PORT="${ISO_RTC_PORT:-18000}"
BINARY=""
ROUNDS="${ROUNDS:-10}"
ROUND_SLEEP="${ROUND_SLEEP:-12}"
OUT="${OUT:-$ISO_PREFIX/logs/gdb-crash.txt}"

fail() { echo "[fail] $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) BINARY="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --out)    OUT="$2";    shift 2 ;;
        *)        fail "unknown option: $1" ;;
    esac
done

command -v gdb >/dev/null 2>&1 || fail "gdb not found; this harness needs it to start nginx"

ISO_PREFIX="$ISO_PREFIX" ISO_HTTP_PORT="$ISO_HTTP_PORT" \
ISO_RTMP_PORT="$ISO_RTMP_PORT" ISO_RTC_PORT="$ISO_RTC_PORT" \
    "$BASE/scripts/isolated-instance.sh" up >/dev/null

if [ -n "$BINARY" ]; then
    [ -x "$BINARY" ] || fail "not executable: $BINARY"
    cp -f "$BINARY" "$ISO_PREFIX/sbin/nginx"
    chmod +x "$ISO_PREFIX/sbin/nginx"
fi

# A traced nginx must own the prefix alone, so the untraced one steps aside.
sed -i 's/^worker_processes .*/worker_processes  1;/' "$ISO_PREFIX/conf/nginx.rtc.conf"
grep -q '^worker_processes  1;' "$ISO_PREFIX/conf/nginx.rtc.conf" \
    || fail "could not force a single worker; did the generated conf change?"

if [ -f "$ISO_PREFIX/logs/nginx.pid" ]; then
    kill "$(cat "$ISO_PREFIX/logs/nginx.pid")" 2>/dev/null || true
    sleep 2
fi
pkill -f '^iso-instance-push' 2>/dev/null || true
sleep 1

mkdir -p "$(dirname "$OUT")"
: > "$OUT"
echo "[gdb] tracing $(basename "$ISO_PREFIX")/sbin/nginx -> $OUT"

# -ex rather than a command file: nothing to write, nothing to clean up. The
# ex commands after `run` execute once the inferior stops on the signal.
( cd "$ISO_PREFIX" && setsid nohup gdb -q -batch \
    -ex "set pagination off" \
    -ex "set confirm off" \
    -ex "set follow-fork-mode child" \
    -ex "set detach-on-fork on" \
    -ex "handle SIGPIPE nostop noprint pass" \
    -ex "handle SIGSEGV stop print" \
    -ex "run" \
    -ex "bt full" \
    -ex "info registers rip rsp rbp rax" \
    -ex "thread apply all bt" \
    --args ./sbin/nginx -p . -c conf/nginx.rtc.conf >"$OUT" 2>&1 < /dev/null & )
sleep 4

# The publisher goes last: it needs the RTMP port to be listening.
"$BASE/scripts/isolated-instance.sh" push >/dev/null
sleep 4

crashed=0
for i in $(seq 1 "$ROUNDS"); do
    if grep -q "SIGSEGV" "$OUT" 2>/dev/null; then
        echo "[gdb] crash caught in round $i"
        crashed=1
        break
    fi
    echo "[churn] round $i/$ROUNDS"
    # The reuse probe is the deterministic driver: three viewers from one client
    # port end up sharing a connection, their idle reaps land seconds apart, and
    # the teardown of the first takes the connection out from under the others.
    # connect_probe.mjs --runs 100 reproduces the same thing by volume instead
    # (about one crash per couple of hundred connects), which is only worth the
    # extra wall clock when the deterministic pattern is not what changed.
    timeout 200 node "$BASE/client/probe_connection_reuse.mjs" \
        --api "http://127.0.0.1:${ISO_HTTP_PORT}" \
        --stream "webrtc://127.0.0.1:${ISO_HTTP_PORT}/live/livestream" \
        --log "$ISO_PREFIX/logs/error.log" \
        --connects 3 --wait 50000 >/dev/null 2>&1 || true
    sleep "$ROUND_SLEEP"
done

if [ "$crashed" -eq 0 ]; then
    echo "[done] no crash in $ROUNDS rounds; nothing to catch (expected for a fixed binary)"
    echo "[done] stop the trace with: pkill -f 'gdb -q -batch'"
    exit 3
fi

echo "[done] stack in $OUT:"
sed -n '/STOPPED\|received signal/,+14p' "$OUT" | head -20
echo "[done] stop the trace with: pkill -f 'gdb -q -batch'"
