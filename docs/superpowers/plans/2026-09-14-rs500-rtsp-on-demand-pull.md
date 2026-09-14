# RS500 On-Demand RTSP Pull Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull the RS500 infrared RTSP stream from OpenResty Lua on demand — the first authorized WebRTC play starts it, 60 s without a subscriber stops it — instead of running a permanent `ffmpeg` supervisor from `run.sh`.

**Architecture:** `conf/auth.lua` records demand in a shared dict after the play token verifies. Worker 0 alone runs a 500 ms maintenance timer that owns one `ngx.pipe` child (`ffmpeg -c copy`), mints the RTMP ingest token from the publish secret, drains the child's stderr, and decides start / respawn / stop from the C module's one-second stats mirror.

**Tech Stack:** OpenResty 1.31.1.1 (nginx 1.31 + LuaJIT), `ngx.pipe` (lua-resty-core), `lua_shared_dict`, existing `ngx_rtmp_rtc_bridge`, ffmpeg CLI, werift client for verification.

**Note:** This plan is executed inline in the same session that authored it, so the code blocks live in the task steps of `docs/rs500-rtsp-to-rtc-design.md` plus the diffs applied to the repository; each step states the exact file, command and expected result.

---

## Task 1: `live/ir` credentials

**Files:**
- Modify: `deploy/nginx/conf/stream_keys.lua`

- [ ] **Step 1: Add a distinct play/publish pair for `live/ir`**

Two freshly generated secrets (`openssl rand -hex 16`), sharing no value with any existing entry, with a comment saying why they must stay distinct.

- [ ] **Step 2: Verify the pairs differ from every other entry**

Run: `python3 - <<'PY'` over `stream_keys.lua`, asserting 4 distinct values for `live/ir|play`, `live/ir|publish` and the `livestream` pair.
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/conf/stream_keys.lua
git commit -m "story-feat(dm): add live/ir credentials for the on-demand RTSP pull"
```

## Task 2: server-side secret accessor

**Files:**
- Modify: `deploy/nginx/conf/config.lua`

- [ ] **Step 1: Add `_M.secret(appstream, purpose)`**

Returns the hot-reloaded secret from the shared dict, or `nil, err` for an unknown purpose. `_M.verify` switches to it so the lookup rule lives in one place.

- [ ] **Step 2: Verify**

Run: `luajit -e 'assert(loadfile("deploy/nginx/conf/config.lua"))'`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/conf/config.lua
git commit -m "story-feat(dm): expose a server-side stream-secret read in config.lua"
```

## Task 3: the pull manager

**Files:**
- Create: `deploy/nginx/conf/rtsp_pull.lua`

- [ ] **Step 1: Write the module**

Module state: one `ngx.pipe` process, its pid, a generation counter, `stopping`/`term_at`, `idle_since`, backoff. Public API: `demand(appstream)`, `start()`, `stop()`.

Invariants to encode, each commented in place:

- Only worker 0 spawns or signals; other workers only `set` the demand key.
- The process object stays referenced in a module upvalue — the C side SIGKILLs it when the Lua object is collected.
- `merge_stderr = true`, `stdout_read_timeout = 0`, `wait_timeout = 0`: one drained stream, no timeout on a multi-hour pull.
- One supervisor light thread per process: drain loop + `wait()`, ended by `p:shutdown("stdout")`.
- Stale supervisors compare their generation before touching shared state.
- Demand key: `set(DEMAND_KEY, ngx.now(), 10)`, keyed to `live/ir` only.

- [ ] **Step 2: Verify it loads and spawns nothing at require time**

Run: `luajit -e 'assert(loadfile("deploy/nginx/conf/rtsp_pull.lua"))'`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/conf/rtsp_pull.lua
git commit -m "story-feat(dm): manage the RTSP pull process from OpenResty Lua"
```

## Task 4: demand on authorized play

**Files:**
- Modify: `deploy/nginx/conf/auth.lua`

- [ ] **Step 1: Call `rtsp_pull.demand()` after `config.verify` succeeds**

Never before: a rejected token must not open a session on the device.

- [ ] **Step 2: Verify**

Run: `luajit -e 'assert(loadfile("deploy/nginx/conf/auth.lua"))'`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/conf/auth.lua
git commit -m "story-feat(dm): demand the RTSP pull from an authorized play request"
```

## Task 5: wire into nginx.conf

**Files:**
- Modify: `deploy/nginx/conf/nginx.conf`

- [ ] **Step 1: `env PATH;` + `env RS500_RTSP_URL;` in the main context**

- [ ] **Step 2: `lua_shared_dict rtsp_pull 1m;` in the http context**

- [ ] **Step 3: `require("rtsp_pull").start()` in `init_worker_by_lua_block`; add `exit_worker_by_lua_block { require("rtsp_pull").stop() }`**

- [ ] **Step 4: Verify the config parses**

```bash
mkdir -p /tmp/rtsp_pull_test/{conf,logs} && cp deploy/nginx/conf/* /tmp/rtsp_pull_test/conf/ \
  && cp build/nginx/nginx/conf/mime.types /tmp/rtsp_pull_test/conf/ \
  && build/nginx/nginx/sbin/nginx -t -p /tmp/rtsp_pull_test -c conf/nginx.conf
```
Expected: `syntax is ok` + `test is successful`.

- [ ] **Step 5: Commit**

```bash
git add deploy/nginx/conf/nginx.conf
git commit -m "story-feat(dm): start and stop the RTSP pull with the nginx worker"
```

## Task 6: player retry while the pull starts

**Files:**
- Modify: `deploy/nginx/html/rtcplayer.html`

- [ ] **Step 1: Retry the signaling POST while `code != 0`**

8 attempts, 800 ms apart, reusing the offer, logging each wait. Rationale: the source cannot exist before the pull it just started, so the first attempt of an idle stream is expected to answer `code != 0`.

- [ ] **Step 2: Verify the page still parses**

Run: `node --check` on the extracted `<script>` body (same technique as the repo's earlier JS check).
Expected: `JS SYNTAX OK`.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/html/rtcplayer.html
git commit -m "story-feat(dm): retry signaling while the on-demand pull starts"
```

## Task 7: end-to-end guard

**Files:**
- Create: `scripts/e2e-rtsp-pull.sh`

- [ ] **Step 1: Write the script**

Stub `ffmpeg` on `PATH` (a shell script that ignores the RTSP input and publishes real `testsrc2` video to the RTMP URL it was handed), then assert:

1. no viewer → no pull process, no `live/ir` source;
2. one viewer → exactly one pull process, `clients=1`, viewer receives video packets (`client/play.mjs`);
3. two viewers → still one pull process;
4. publisher killed under a live viewer → a new pid within the backoff;
5. viewers gone → the process is stopped after the idle window;
6. `run.sh stop` → no leftover pull process, orderly-stop line in the log;
7. bad signature → no process;
8. no `ffmpeg` on `PATH` → play still answers, server stays up.

- [ ] **Step 2: Run it**

Run: `scripts/e2e-rtsp-pull.sh`
Expected: every step prints `[PASS]`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/e2e-rtsp-pull.sh
git commit -m "story-test(dm): guard the on-demand RTSP pull end to end"
```

## Task 8: documentation

**Files:**
- Modify: `docs/rs500-rtsp-to-rtc-design.md`
- Modify: `docs/测试文档.md`

- [ ] **Step 1: Record the player retry and the final file list in the design doc**

- [ ] **Step 2: Add the new e2e script to the test document**

- [ ] **Step 3: Commit**

```bash
git add docs/rs500-rtsp-to-rtc-design.md docs/测试文档.md
git commit -m "story-docs(dm): document the on-demand RTSP pull and its guard"
```

## Self-Review

- Design §3.1 (demand on authorized play, worker-0 ownership) → Tasks 3, 4, 5.
- Design §3.2 (60 s idle reclaim from `clients`, demand window) → Task 3, verified by Task 7 steps 1, 2, 5.
- Design §3.3 (generation guard, SIGTERM→SIGKILL, worker-exit cleanup, no secrets in logs) → Task 3, verified by Task 7 steps 4, 6.
- Design §4 (file list) → Tasks 1–6; `rtcplayer.html` is added to the design doc in Task 8 because the first attempt of an idle stream cannot succeed without a retry.
- Design §5 regression items (bad token, rate limit, missing ffmpeg) → Task 7 steps 7, 8.
