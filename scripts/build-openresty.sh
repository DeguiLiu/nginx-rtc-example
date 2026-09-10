#!/usr/bin/env bash
# build-openresty.sh - configure + build + install OpenResty with this repo's
# self-written module nginx-rtc-module and nginx-http-flv-module, both fetched
# from pinned git tags by scripts/fetch-deps.sh (no C source lives in this repo).
#
#   prefix:         $OPENRESTY_PREFIX (default build/nginx)
#   openresty src:  $OPENRESTY_SRC (use an existing checkout, no fetch) else
#                   fetch openresty-1.31.1.1 via scripts/fetch-deps.sh
#   module src:     $NGX_RTC_MODULE_SRC (local checkout override, e.g. when
#                   iterating on the module without bumping its pinned tag)
#                   else staged from cache into build/src/nginx-rtc-module
#   third libs:     $NGX_RTC_THIRD (default build/third), produced by
#                   build-deps.sh or an existing prebuilt tree.
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$BASE/build"
CACHE="$BASE/scripts/_cache"
ORX="${OPENRESTY_PREFIX:-$BUILD/nginx}"
THIRD="${NGX_RTC_THIRD:-$BUILD/third}"
JOBS=${JOBS:-"$(nproc)"}
mkdir -p "$BUILD/src"

# stage a fetched git dep from cache into build/src (idempotent)
stage_git() { # <name> <marker-file>
    local name marker dst
    name="$1"
    marker="$2"
    dst="$BUILD/src/$name"
    if [ -f "$dst/$marker" ]; then return 0; fi
    [ -d "$CACHE/$name/.git" ] || { echo "run scripts/fetch-deps.sh first ($name)"; exit 1; }
    echo "== $name source: stage from cache =="
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -r "$CACHE/$name"/. "$dst"/
}

# --- openresty source ---
if [ -n "${OPENRESTY_SRC:-}" ]; then
    OS="$OPENRESTY_SRC"
    echo "== openresty source (env): $OS =="
else
    TAR="openresty-1.31.1.1.tar.gz"
    [ -s "$CACHE/$TAR" ] || { echo "run scripts/fetch-deps.sh first"; exit 1; }
    echo "== openresty source: extract $TAR =="
    OS="$BUILD/src/openresty-1.31.1.1"
    rm -rf "$OS"
    tar -xzf "$CACHE/$TAR" -C "$BUILD/src"
fi

[ -d "$THIRD/lib" ] || { echo "third libs missing under $THIRD - run build-deps.sh or set NGX_RTC_THIRD"; exit 1; }

# --- addon sources: nginx-rtc-module + nginx-http-flv-module ---
if [ -n "${NGX_RTC_MODULE_SRC:-}" ]; then
    MOD="$NGX_RTC_MODULE_SRC"
    echo "== module addon source (env): $MOD =="
else
    MOD="$BUILD/src/nginx-rtc-module"
    stage_git nginx-rtc-module config
fi
HFLV="$BUILD/src/nginx-http-flv-module"
stage_git nginx-http-flv-module config

echo "== configure (prefix=$ORX, third=$THIRD, module=$MOD, http-flv=$HFLV) =="

# Optional extra compiler/linker options, e.g. for a sanitizer build:
#
#   EXTRA_CC_OPT="-fsanitize=address,undefined \
#                 -fno-sanitize=alignment -fno-sanitize=nonnull-attribute \
#                 -fno-omit-frame-pointer -O1" \
#   EXTRA_LD_OPT="-fsanitize=address,undefined" \
#     scripts/build-openresty.sh
#
# Four things that are easy to get wrong:
#
#   * The whole build must run under `setarch $(uname -m) -R`. ASan's shadow
#     mapping collides with this host's high-entropy mmap ASLR, and nginx's
#     configure compiles AND RUNS probe programs (auto/types/sizeof,
#     auto/endianness) that are instrumented like everything else. Without the
#     personality flag they die in a DEADLYSIGNAL loop and configure blames the
#     compiler:
#
#         checking for long size ... AddressSanitizer:DEADLYSIGNAL (x6)
#         Segmentation fault (core dumped)
#         ./configure: error: can not detect long size
#
#     The recipe is therefore
#         setarch $(uname -m) -R env ASAN_OPTIONS=... EXTRA_CC_OPT=... \
#             scripts/build-openresty.sh
#     not a bare invocation. The personality flag survives fork and exec, so
#     every probe inherits it. Stopping here, because the message reads like a
#     toolchain problem, is the expensive mistake -- the sanitizer itself is
#     fine and the identical build succeeds one wrapper later.
#   * -fsanitize must appear in BOTH. nginx's link rule is
#     `$(LINK) ... $ngx_libs` and does not include CFLAGS, so cc-opt alone
#     gives "undefined reference to __asan_*" at link time.
#   * -O1 belongs in EXTRA_CC_OPT. OpenResty pushes its own -O2 first and the
#     user cc-opt after, so the later flag wins; without it the sanitizer runs
#     at -O2, which folds away some use-after-scope checks and skews line
#     numbers. The same ordering rule makes the two -fno-sanitize= flags below
#     effective: they must come AFTER -fsanitize=, which they do here.
#   * The two -fno-sanitize= flags suppress ~486 reports per e2e run that are
#     all third-party and all benign, and they are deliberately a build-flag
#     choice rather than patches to the source.
#
#     alignment -- stock nginx-rtmp's shared-buffer allocator reserves
#     NGX_RTMP_REFCOUNT_BYTES (= sizeof(uint32_t) = 4) at the head of a block
#     and carves the ngx_chain_t and ngx_buf_t out of what follows, while
#     ngx_rtmp_ref() reads *((T *) (b) - 1): the chain lands at block+4 and the
#     buffer at block+20, both 4 mod 8, so every NGX_RTMP_USER_OUT* store
#     touches a misaligned ngx_buf_t. A dozen more are protocol fields read
#     through *(uint32_t *) at offsets 1, 2 and 5, which the wire format
#     requires. ~483 reports.
#
#     nonnull-attribute -- zero-length memcpy with a NULL source, three sites:
#     ngx_rtmp_log_module.c:253 (an empty log-format variable), and twice
#     ngx_rtmp_init.c:136 logging "*%ui client connected '%V'" through
#     ngx_string.c:586, where c->addr_text is never set for the auto-push
#     relay's unix-socket connection -- which is why that line reads
#     "client connected ''". 3 reports.
#
#     All of it is real UB and UBSan is right to flag it, but none of it has
#     ever faulted on x86-64, all of it is upstream code this repo does not
#     modify, and none of the reports have ever come from our own module. The
#     only thing they cost is drowning the findings that do matter, so the
#     checks are switched off. If either class comes back, the ASan nginx was
#     rebuilt without these flags.
#
# Also set ASAN_OPTIONS=detect_leaks=0 for the build itself: configure compiles
# and RUNS probe programs (auto/types/sizeof, auto/endianness), and a leak report
# from one of those would be misread as a capability-probe failure.
EXTRA_CC_OPT=${EXTRA_CC_OPT:-}
EXTRA_LD_OPT=${EXTRA_LD_OPT:-}

CC_OPT_ARGS=()
LD_OPT_ARGS=()
if [ -n "$EXTRA_CC_OPT" ]; then
    CC_OPT_ARGS=(--with-cc-opt="$EXTRA_CC_OPT")
    echo "   extra cc-opt: $EXTRA_CC_OPT"
fi

LD_OPT_FULL="-Wl,-rpath,$ORX/luajit/lib"
if [ -n "$EXTRA_LD_OPT" ]; then
    LD_OPT_FULL="$EXTRA_LD_OPT $LD_OPT_FULL"
    echo "   extra ld-opt: $EXTRA_LD_OPT"
fi
LD_OPT_ARGS=(--with-ld-opt="$LD_OPT_FULL")

( cd "$OS" \
    && NGX_RTC_THIRD="$THIRD" ./configure \
        --prefix="$ORX" \
        "${CC_OPT_ARGS[@]}" \
        "${LD_OPT_ARGS[@]}" \
        --add-module="$MOD" \
        --add-module="$HFLV" )

echo "== make -j$JOBS && make install =="
( cd "$OS" && make -j"$JOBS" >/dev/null && make install >/dev/null )

echo "[done] nginx installed under $ORX"

# Record which addon revision this prefix was built from. Without it, a stale
# staged copy under build/src/nginx-rtc-module silently yields an nginx that
# behaves differently from the local checkout, and an e2e run against it reads
# as a regression in the code under test.
#
# The recorded rev is the module's HEAD commit, so it does NOT describe an
# uncommitted working tree -- which is the normal state while iterating, and the
# one that matters. e2e-asan.sh therefore guards against a stale prefix by mtime
# (its src/ vs this binary), not by this file.
{
    if [ -d "$MOD/.git" ]; then
        git -C "$MOD" rev-parse HEAD 2>/dev/null || echo unknown
        git -C "$MOD" log -1 --format='%h %ad %s' 2>/dev/null || true
    else
        echo "unknown (no .git under $MOD)"
    fi
} > "$ORX/MODULE_REV" 2>/dev/null || true
echo "  addon source: $MOD"
echo "  addon rev:    $(head -1 "$ORX/MODULE_REV" 2>/dev/null || echo '?')"

echo "  next:  ./run.sh nginx   (syncs deploy conf/html and starts it)"
