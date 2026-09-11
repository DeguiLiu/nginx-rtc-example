#!/usr/bin/env bash
# e2e-asan.sh - run the end-to-end paths against an AddressSanitizer build of
# nginx, then put the normal instance back.
#
#   scripts/e2e-asan.sh [ASAN_PREFIX]
#
# Why the running instance has to stop first: deploy/nginx/conf/nginx.conf
# binds 1935 (RTMP) and 18082 (HTTP) without `reuseport`, so a second nginx
# fails at bind() with EADDRINUSE before it ever serves a request. The RTC
# plane's `listen 8000 udp reuseport` is worse if only that one were changed --
# both sockets would bind, and the kernel hashes each client's packets to one
# of them, so signaling would land on the new instance while the media went to
# the old one. Restoring the normal instance is the last step here, and the
# trap below does it even if the run dies early.
#
# ASLR has to be off for the sanitized nginx too, not just for the host tests:
# with it on, this host kills ~30% of ASan processes during startup with a
# DEADLYSIGNAL loop (see scripts/sanitize-tests.sh in nginx-rtc-module).
# `setarch -R` sets a personality flag that survives fork and exec, so wrapping
# the launcher covers the master and every worker.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
# OpenResty installs a bundle at --prefix and nginx itself under <prefix>/nginx,
# which is why the production instance lives at build/nginx/nginx too. The two
# levels are load-bearing: scripts/build-openresty.sh was invoked with
# OPENRESTY_PREFIX=build/nginx-asan/nginx, so the sanitized nginx is at
# build/nginx-asan/nginx/nginx. The shorter path is NOT a synonym -- it is the
# bundle root, and a build that once used it directly left its own sbin/nginx
# there (Sep 10, against a different luajit). A run pointed at it tests that
# binary instead of the current source, so the shape is checked below.
ASAN_PREFIX=${1:-"$BASE/build/nginx-asan/nginx/nginx"}
NORMAL_PREFIX="$BASE/build/nginx/nginx"

KEEP_PUSH_PID=/tmp/rtc_keep_push.pid   # run.sh's supervisor pidfiles
KEEP_TC_PID=/tmp/rtc_keep_tc.pid

NORMAL_WAS_RUNNING=0
NORMAL_HAD_SUPERVISORS=0

supervisor_up() {   # pidfile -> 0 when its supervisor is alive
    local pid
    [ -f "$1" ] || return 1
    pid="$(cat "$1" 2>/dev/null)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# A bundle root carries sbin/nginx of its own, so it satisfies the -x check
# below while being the wrong directory. The tell is the nested install.
if [ -x "$ASAN_PREFIX/nginx/sbin/nginx" ]; then
    echo "$ASAN_PREFIX is an OpenResty bundle root, not nginx's own prefix." >&2
    echo "  Its sbin/nginx belongs to whichever build last installed there; the" >&2
    echo "  current one is under nginx/. Pass the nested path:" >&2
    echo "    $ASAN_PREFIX/nginx" >&2
    exit 1
fi

if [ ! -x "$ASAN_PREFIX/sbin/nginx" ]; then
    echo "no sanitized nginx at $ASAN_PREFIX/sbin/nginx" >&2
    echo "build it first, see docs or scripts/build-openresty.sh with EXTRA_CC_OPT" >&2
    exit 1
fi

# A stale sanitized build reports a clean run for code it never compiled, and
# the report cannot tell you that -- it looks exactly like a clean run. MODULE_REV
# next to the binary does not help: it records the module's HEAD commit, and the
# case that matters is an uncommitted working tree, which is the normal state
# while iterating. This was found the hard way -- an ASan binary two hours older
# than src/ ran a full e2e and said nothing about the code under test -- so the
# comparison is by mtime and the run stops before it touches the live instance.
MOD_SRC="$BASE/../nginx-rtc-module/src"
if [ -d "$MOD_SRC" ]; then
    NEWER=$(find "$MOD_SRC" -name '*.[ch]' -newer "$ASAN_PREFIX/sbin/nginx" \
                -print -quit 2>/dev/null || true)
    if [ -n "$NEWER" ]; then
        echo "STALE sanitized build: $NEWER" >&2
        echo "  is newer than $ASAN_PREFIX/sbin/nginx." >&2
        echo "  Rebuild it under setarch, or this e2e tests the previous module:" >&2
        echo "    setarch \$(uname -m) -R env NGX_RTC_MODULE_SRC=$BASE/../nginx-rtc-module \\" >&2
        echo "      EXTRA_CC_OPT='-fsanitize=address,undefined ...' \\" >&2
        echo "      EXTRA_LD_OPT='-fsanitize=address,undefined' \\" >&2
        echo "      scripts/build-openresty.sh" >&2
        exit 1
    fi
fi

mkdir -p "$ASAN_PREFIX/logs"

# log_path, not stderr: nginx's error_log redirect makes fd 2 point at
# error.log, but that is a side effect of the configuration, not a guarantee --
# and a worker that dies before that redirect would lose its report. With
# log_path every process writes its own asan.<pid>.
#
# handle_*=2 is what makes the fatal-signal reports survive: the module installs
# its own SIGSEGV/SIGABRT/... handlers from init_process (ngx_rtc_shm.c), and
# with the default handle_segv=1 they silently replace ASan's. At 2, ASan blocks
# the replacement -- the module's sigaction even returns success while doing
# nothing. The two cannot coexist in this libasan version; this run chooses
# ASan's reports and therefore loses the module's own backtrace.
#
# detect_leaks=0: LeakSanitizer scans LuaJIT's mmap GC areas and JIT stacks,
# which is slow and reports objects that are still rooted in the VM.
# detect_stack_use_after_return=0: the fake stack interferes with LuaJIT's
# interpreter and coroutine stacks.
# allocator_may_return_null=1: keep nginx's own allocation-failure handling
# instead of having ASan abort on the first failed allocation.
export ASAN_OPTIONS="log_path=$ASAN_PREFIX/logs/asan\
:detect_leaks=0\
:detect_stack_use_after_return=0\
:abort_on_error=0\
:allocator_may_return_null=1\
:quarantine_size_mb=64\
:malloc_context_size=15\
:handle_segv=2:handle_sigbus=2:handle_abort=2:handle_sigill=2:handle_sigfpe=2:handle_sigtrap=2\
:symbolize=1:allow_addr2line=1"

# Every process launched out of the ASan prefix needs ASLR off -- including the
# short-lived ones. `nginx -s stop` is itself an ASan process: without this it
# dies in the DEADLYSIGNAL loop before sending anything, the stop silently does
# nothing, the ports stay held, and the normal instance cannot come back.
# That failure mode is invisible in the stop's own exit status.
#
# The same applies to ASAN_OPTIONS: a hand-started instance (a one-off probe,
# a manual push test) that does NOT inherit this environment gets
# detect_leaks=1 and LSan will report nginx's per-process event/connection
# arrays -- which nginx never frees and process exit reclaims -- as leaks in
# ngx_event_process_init. That is noise, not a finding, and it is easy to
# mistake for one. Start ASan instances through this script or asanctl below,
# never by hand.
asanctl() {
    setarch "$(uname -m)" -R env OPENRESTY_PREFIX="$ASAN_PREFIX" "$BASE/run.sh" "$@"
}

restore() {
    local rc=$?

    echo
    echo "== restore =="
    set +e
    asanctl stop >/dev/null 2>&1

    # Verify the ports are actually free before starting the normal instance:
    # a silent stop failure is exactly how the normal instance ends up unable
    # to bind, and that is easy to miss in the tail of a long run.
    for _ in $(seq 1 10); do
        ss -lnt 2>/dev/null | grep -qE ':(1935|18082)\s' || break
        sleep 1
    done
    if ss -lnt 2>/dev/null | grep -qE ':(1935|18082)\s'; then
        echo "   WARNING: ports still held after stopping the ASan instance" >&2
    fi

    if [ "$NORMAL_WAS_RUNNING" = 1 ]; then
        # `run.sh stop` above tears the keep-push / keep-transcode supervisors
        # down along with nginx, so restoring nginx alone leaves a tree that
        # answers /rtc/v1/stats with an empty streams[] and pushes nothing --
        # healthy-looking, and useless for the next check that reads it. Start
        # back exactly what was there: `run.sh start` when the supervisors were
        # up, `nginx` when only nginx was.
        if [ "$NORMAL_HAD_SUPERVISORS" = 1 ]; then
            OPENRESTY_PREFIX="$NORMAL_PREFIX" "$BASE/run.sh" start >/dev/null 2>&1
        else
            OPENRESTY_PREFIX="$NORMAL_PREFIX" "$BASE/run.sh" nginx >/dev/null 2>&1
        fi
        # Poll, do not curl once: `run.sh nginx` returns as soon as the master
        # forks, well before the workers are accepting. A single 3s probe here
        # reports "did not come back up" on a restore that in fact succeeded,
        # which is worse than no check at all -- it sends the next reader
        # hunting for a port conflict that is not there.
        for _ in $(seq 1 25); do
            curl -fsS --max-time 2 http://127.0.0.1:18082/rtc/v1/stats >/dev/null 2>&1 && break
            sleep 1
        done
        if curl -fsS --max-time 2 http://127.0.0.1:18082/rtc/v1/stats >/dev/null 2>&1; then
            echo "   normal instance restarted ($NORMAL_PREFIX)"
            echo "   serving pid: $(pgrep -f 'sbin/nginx -p \. -c conf/nginx.rtc.conf' | head -1)"
            echo "   exe:         $(readlink "/proc/$(pgrep -f 'sbin/nginx -p \. -c conf/nginx.rtc.conf' | head -1)/exe" 2>/dev/null)"
        else
            echo "   ERROR: normal instance did not come back up" >&2
        fi
        if [ "$NORMAL_HAD_SUPERVISORS" = 1 ]; then
            # The supervisors write their pidfiles themselves, so their presence
            # is the direct signal; ffmpeg takes a moment to be spawned.
            for _ in $(seq 1 20); do
                supervisor_up "$KEEP_PUSH_PID" && supervisor_up "$KEEP_TC_PID" && break
                sleep 1
            done
            if supervisor_up "$KEEP_PUSH_PID" && supervisor_up "$KEEP_TC_PID"; then
                echo "   supervisors back (keep-push, keep-transcode)"
            else
                echo "   ERROR: supervisors did not come back; run ./run.sh start" >&2
            fi
        fi
    else
        echo "   normal instance was not running before; left stopped"
    fi
    exit $rc
}
trap restore EXIT

# --- 0. remember what we are about to disrupt -----------------------------
if curl -fsS --max-time 2 http://127.0.0.1:18082/rtc/v1/stats >/dev/null 2>&1; then
    NORMAL_WAS_RUNNING=1
    # Captured before the stop, because `run.sh stop` takes the supervisors with
    # it: after it, a pidfile that is gone says nothing about what was running.
    if supervisor_up "$KEEP_PUSH_PID" || supervisor_up "$KEEP_TC_PID"; then
        NORMAL_HAD_SUPERVISORS=1
    fi
    echo "[0] normal instance is up (supervisors: $NORMAL_HAD_SUPERVISORS); it will be stopped and restored at the end"
    OPENRESTY_PREFIX="$NORMAL_PREFIX" "$BASE/run.sh" stop >/dev/null 2>&1 || true
    sleep 1
fi

# --- 1. sanitized instance -------------------------------------------------
echo "[1] starting the ASan instance ($ASAN_PREFIX)"
rm -f "$ASAN_PREFIX"/logs/asan.* 2>/dev/null || true

# The stderr sink has to be cleared too, and it is the one that gets forgotten.
# nginx appends to error.log, and the UBSan lines that land there carry no nginx
# timestamp of their own -- they are raw runtime output interleaved into the
# stream. So a file spanning two runs cannot attribute its reports to either
# one, and a run against a fixed build inherits the previous run's findings and
# reads as a regression that is not there. Measured: a log left from a
# pre-suppression build made a clean run look like 485 findings.
: > "$ASAN_PREFIX/logs/error.log"

asanctl nginx

for _ in $(seq 1 20); do
    curl -fsS --max-time 2 http://127.0.0.1:18082/rtc/v1/stats >/dev/null 2>&1 && break
    sleep 1
done

if ! curl -fsS --max-time 2 http://127.0.0.1:18082/rtc/v1/stats >/dev/null 2>&1; then
    echo "ASan nginx did not answer /rtc/v1/stats within 20s" >&2
    tail -20 "$ASAN_PREFIX/logs/error.log" 2>/dev/null >&2 || true
    exit 1
fi
echo "    up"

# --- 2. e2e paths ----------------------------------------------------------
FAILED=0
run_step() {
    local name="$1"; shift
    echo
    echo "[2] $name"
    if "$@"; then
        echo "    OK"
    else
        echo "    FAILED (rc=$?)"
        FAILED=$((FAILED + 1))
    fi
}

# RTMP -> WebRTC: the bridge module feeding RTP/SRTP to a viewer.
run_step "RTMP push + webrtc play" bash -c '
    set -e
    "'"$BASE"'/run.sh" push >/tmp/asan-push.log 2>&1 &
    PUSH=$!
    sleep 5
    node "'"$BASE"'/client/play.mjs" >/tmp/asan-play.log 2>&1
    rc=$?
    kill $PUSH 2>/dev/null || true
    wait $PUSH 2>/dev/null || true
    [ $rc -eq 0 ] || { tail -20 /tmp/asan-play.log; exit 1; }
    tail -5 /tmp/asan-play.log
'

# WHIP ingest: DTLS handshake, SRTP keying, session creation in the glue layer.
# whip_push.mjs signs its own ingest token from WHIP_KEY (see conf/whip_auth.lua
# for the check), so the only thing this needs from the deploy config is the
# publish secret -- no second copy of the token algorithm here.
run_step "WHIP publish" env WHIP_KEY="$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"\[\"live/whiptest\|publish\"\]\s*=\s*\"([^\"]+)\"", src)
print(m.group(1) if m else "")
' "$BASE/deploy/nginx/conf/stream_keys.lua")" WHIP_STREAM=whiptest WHIP_DURATION=6000 \
    node "$BASE/client/whip_push.mjs"

# Publish-ownership arbitration (the regression guard from the FSM review).
run_step "WHIP release + RTMP takeover" "$BASE/scripts/e2e-whip-release.sh"

# --- 3. collect ------------------------------------------------------------
#
# There are TWO sinks and looking at only one is how a run happily reports
# "none" while reports are sitting on disk. With log_path in ASAN_OPTIONS,
# reports go to logs/asan.<pid>. Without it -- a process started outside this
# script, or any run where the options did not propagate -- ASan writes to
# stderr, and nginx has already dup2'd stderr onto logs/error.log, so the
# report lands there instead. The second sink is the easy one to miss.
#
# What is expected in this report: nothing -- and that is now a statement rather
# than a hope. Two classes of third-party UBSan noise used to appear here; both
# are suppressed at the build-flag level (see scripts/build-openresty.sh), so
# anything printed below is a finding to chase:
#
#   * alignment, ~483/run. Every one came from stock nginx-rtmp: its
#     shared-buffer allocator puts the ngx_chain_t at block+4 and the ngx_buf_t
#     at block+20, and a dozen more are *(uint32_t *) casts on protocol fields
#     at offsets the wire format mandates.
#   * nonnull-attribute, 3/run, all zero-length memcpy with a NULL source:
#     ngx_rtmp_log_module.c:253 for an empty log-format variable, and twice
#     ngx_rtmp_init.c:136 -> ngx_string.c:586 logging "client connected '%V'"
#     for the auto-push relay's unix-socket connection, where c->addr_text is
#     never set. That is the line that reads client connected ''.
#
# None of it has ever faulted on x86-64 and none of it has ever come from our
# own module, which is why those two checks are switched off rather than patched
# out of third-party source. If either class reappears, the ASan nginx was
# rebuilt without the -fno-sanitize= flags.
#
# Exactly one third-party report is expected and is deliberately NOT suppressed:
#
#   * vla-bound, 2 lines from one site per run: ngx_rtmp_amf.c:193 declares
#     `char name[maxlen]`, and maxlen is 0 whenever the object being parsed has
#     no named element. C11 6.7.6.2p5 requires a VLA bound greater than zero, so
#     UBSan is right to flag it. It cannot fault, and that was checked rather
#     than assumed: both ngx_rtmp_amf_get calls that fill `name` are bounded by
#     maxlen -- zero bytes when maxlen is zero -- and every ngx_strncmp that
#     would read it is short-circuited away first, by `n < nelts` when the
#     element list is empty and by `len != elts[n].name.len` when only the
#     names are empty.
#
#     The two checks above are switched off because they arrive ~486 times per
#     run and bury everything else. This one site buries nothing, and vla-bound
#     is the check that would catch the mistake if this module ever grows a VLA
#     (nginx-rtc-module/src has none today, which is why the check is kept
#     rather than traded away for a tidier report). Anything beyond these two
#     lines, or any change in their count or location, is a finding.
echo
echo "== sanitizer reports =="
FOUND=0

for f in "$ASAN_PREFIX"/logs/asan.*; do
    [ -f "$f" ] || continue
    FOUND=1
    echo "--- $f ---"
    grep -E "ERROR: (Address|Leak|Thread)Sanitizer|SUMMARY: AddressSanitizer|runtime error:" "$f" \
        | head -8 || true
done

ERRLOG="$ASAN_PREFIX/logs/error.log"
IN_ERRLOG=$(grep -cE "ERROR: (Address|Leak|Thread)Sanitizer|runtime error:" "$ERRLOG" 2>/dev/null || true)
if [ -n "$IN_ERRLOG" ] && [ "$IN_ERRLOG" != 0 ]; then
    FOUND=1
    echo "--- logs/error.log (the stderr sink) ---"
    grep -E "ERROR: (Address|Leak|Thread)Sanitizer|SUMMARY: AddressSanitizer|runtime error:" "$ERRLOG" \
        | sort -u | head -8 || true
fi

[ "$FOUND" = 0 ] && echo "    none"

echo
echo "== e2e steps failed: $FAILED =="
[ "$FAILED" -eq 0 ]
