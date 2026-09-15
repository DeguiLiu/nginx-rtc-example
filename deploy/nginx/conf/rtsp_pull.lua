-- conf/rtsp_pull.lua - on-demand RTSP -> RTMP pull, owned by exactly one worker.
--
-- The RS500 infrared stream is only worth pulling while somebody watches it: the
-- device serves RTSP from a single-threaded select loop, and the RTSP session
-- plus the RTMP publish cost this host bandwidth. So the first authorized play
-- request starts the pull, and the pull is stopped once no WebRTC subscriber is
-- left.
--
-- Who owns the process. ngx.pipe spawns the child with fork/execvp from the
-- worker that calls spawn(), so the child belongs to that worker: the Lua
-- process object is SIGKILLed when it is garbage collected, and a worker's Lua
-- state is collected when the worker exits. Two workers each starting a pull
-- would also fight over the device's single RTSP session. worker 0 is therefore
-- the only worker that spawns, waits and signals; every worker may record
-- demand, which is what the shared dict is for.
--
-- Why demand exists next to the client count. `clients` in the C stats mirror
-- counts sessions that finished DTLS/SRTP and subscribed, so the viewer that
-- triggers the pull is invisible for the ~1 s its handshake takes. The demand
-- key covers that window and keeps the pull up across a respawn. It is short
-- lived on purpose: a one-shot play request, or a worker that died right after
-- recording demand, cannot keep a camera session open for long.

local ngx = ngx
local cjson = require "cjson"
local hmac = require "hmac"
local config = require "config"

local _M = { _VERSION = "0.1" }

local STREAM = "live/ir"
local DEMAND_KEY = "demand:" .. STREAM

local TICK_SECONDS = 0.5   -- maintenance period; bounds the start latency
local DEMAND_TTL   = 10    -- seconds one play request keeps the pull wanted
local IDLE_SECONDS = 60    -- no subscriber this long -> stop the pull
local MAX_BACKOFF  = 30    -- cap on the respawn delay after an unexpected exit
local TERM_GRACE   = 5     -- seconds between SIGTERM and SIGKILL
local STDERR_KEEP  = 2000  -- bytes of ffmpeg output kept for the log
local READ_CHUNK   = 4096  -- bytes per stdout_read_any() call (the argument is not optional)

-- Where the pulled stream is published, as a prefix (the stream name and the
-- token are appended). Overridable because a second instance on this host does
-- not own 1935: scripts/isolated-instance.sh runs one on 11935, and a pull that
-- keeps aiming at 1935 would publish into whatever instance happens to own it
-- -- the isolated one would then never see the source it started.
local RTMP_PREFIX = os.getenv("RS500_RTMP_PREFIX") or "rtmp://127.0.0.1:1935/"
if "/" ~= RTMP_PREFIX:sub(-1) then
    RTMP_PREFIX = RTMP_PREFIX .. "/"
end

-- POSIX signal numbers, the only platforms ngx.pipe supports.
local SIGTERM, SIGKILL = 15, 9

-- An OpenResty built without the socket_cloexec patch has no ngx.pipe, and
-- playback must keep working there: a play request then simply never gets a pull
-- started. Loading it up front also keeps the failure to one log line at start
-- rather than one per play request.
local have_pipe, pipe = pcall(require, "ngx.pipe")

-- worker 0 local state. `proc` must stay reachable from a live upvalue: the C
-- side kills the child when the Lua process object is collected.
local proc                 -- ngx.pipe process object, or nil
local proc_pid = 0
local generation = 0       -- bumped per spawn; stale supervisors compare against it
local stopping = false     -- true between SIGTERM and the exit that follows it
local term_at = 0          -- ngx.now() when SIGTERM was sent (0 = not sent)
local idle_since = 0       -- ngx.time() when the last subscriber left (0 = not idle)
local next_try = 0         -- ngx.time() before which no respawn is attempted
local backoff = 1          -- seconds, doubled per consecutive failure
local stderr_tail = ""

-- Called by conf/auth.lua once a play token verified. Best effort by design: an
-- otherwise authorized play must not fail because this write did. Only the one
-- stream this module pulls is registered -- a demand key per stream would leak
-- memory for every name a client invents.
function _M.demand(appstream)
    if appstream ~= STREAM then
        return false
    end

    local ok, err = ngx.shared.rtsp_pull:set(DEMAND_KEY, ngx.now(), DEMAND_TTL)
    if not ok then
        ngx.log(ngx.ERR, "rtsp_pull: demand set failed: ", err)
        return false
    end
    return true
end

-- Ready WebRTC subscribers of STREAM, out of the C module's one-second stats
-- mirror. nil means "no source" (so nobody can be watching) or "mirror not
-- written yet"; both are treated as zero by the caller.
local function viewer_count()
    local raw = ngx.shared.rtc_stats:get("stats")
    if not raw then
        return nil
    end
    local ok, decoded = pcall(cjson.decode, raw)
    if not ok or "table" ~= type(decoded) or "table" ~= type(decoded.streams) then
        return nil
    end
    for _, s in ipairs(decoded.streams) do
        if s.name == STREAM then
            return tonumber(s.clients) or 0
        end
    end
    return nil
end

-- One light thread per process: drain the merged stdout+stderr and wait for the
-- exit that decides whether to respawn.
--
-- The drain is not optional. ffmpeg writes to stderr, and an undrained pipe
-- fills up and blocks the writer: the process stays alive while its media stops,
-- which reads as a frozen stream with a healthy pid.
--
-- The thread is spawned from a timer callback, which may yield. It outlives the
-- callback that created it: a pending light thread keeps the fake request alive
-- (ngx_http_lua_run_thread returns NGX_AGAIN while ctx->uthreads is non-zero),
-- so a pull that runs for hours is not torn down when the tick returns.
local function supervise(p, my_generation)
    ngx.thread.spawn(function()
        local drain = ngx.thread.spawn(function()
            local tail = ""
            while true do
                local data, err = p:stdout_read_any(READ_CHUNK)
                if not data then
                    -- "closed" is the normal end: the owner shut the stream
                    -- down after the child exited. Anything else is worth one
                    -- line, and neither case may spin here.
                    if err and err ~= "closed" then
                        ngx.log(ngx.INFO, "rtsp_pull: read ended: ", err)
                    end
                    stderr_tail = tail
                    return
                end
                tail = (tail .. data):sub(-STDERR_KEEP)
            end
        end)

        local ok, reason, status = p:wait()
        -- Unblocks the reader: shutdown aborts a light thread sitting in a read,
        -- which is why the reader needs no timeout of its own.
        p:shutdown("stdout")
        ngx.thread.wait(drain)

        -- A supervisor from an earlier generation must not touch state that
        -- belongs to the process now running: its exit is already accounted for.
        if generation ~= my_generation then
            return
        end

        local was_stopping = stopping
        proc, proc_pid = nil, 0
        stopping, term_at = false, 0

        if was_stopping then
            backoff = 1
            ngx.log(ngx.INFO, "rtsp_pull: stopped: ", reason, " status=", status)
        else
            ngx.log(ngx.ERR, "rtsp_pull: ffmpeg exited: ", reason, " status=",
                    status, " tail=", stderr_tail)
            next_try = ngx.time() + backoff
            backoff = math.min(backoff * 2, MAX_BACKOFF)
        end
    end)
end

-- Mint the ingest token here, from the published secret in the hot-reloaded
-- shared dict. The token never has to be configured, is re-minted on every
-- respawn (so it cannot be the thing that expires under a long pull), and the
-- publish secret stays server-side -- only the play secret ships in the player
-- pages.
local function start_pull()
    local url = os.getenv("RS500_RTSP_URL")
    if not url or "" == url then
        ngx.log(ngx.ERR, "rtsp_pull: RS500_RTSP_URL is not set; not pulling ", STREAM)
        return false
    end

    local secret = config.secret(STREAM, "publish")
    if not secret or "string" ~= type(secret) then
        ngx.log(ngx.ERR, "rtsp_pull: no publish secret for ", STREAM, "; not pulling")
        return false
    end
    local exp = ngx.time() + 3600
    local sign = hmac.sign(secret, STREAM .. "|t=" .. exp)
    if not sign then
        ngx.log(ngx.ERR, "rtsp_pull: cannot sign the ingest token")
        return false
    end

    local args = {
        "ffmpeg",
        "-nostdin",                                   -- never wait on our stdin
        "-loglevel", "warning",                       -- the tail is logged, nothing else
        "-rtsp_transport", "tcp",                     -- NAT-safe; see the design doc
        "-allowed_media_types", "video",              -- the device has no audio
        "-timeout", "10000000",                       -- 10 s socket I/O timeout
        "-i", url,
        "-c", "copy",                                 -- no re-encode, no CPU
        "-f", "flv",
        RTMP_PREFIX .. STREAM .. "?t=" .. exp .. "&sign=" .. sign,
    }
    local p, err = pipe.spawn(args, {
        merge_stderr = true,          -- one stream to drain, see supervise()
        stdout_read_timeout = 0,      -- a quiet ffmpeg is normal; never time out
        wait_timeout = 0,             -- a pull runs for hours, not 10 s
    })
    if not p then
        ngx.log(ngx.ERR, "rtsp_pull: spawn failed: ", err)
        return false
    end

    proc = p
    proc_pid = p:pid()
    generation = generation + 1
    stopping, term_at, idle_since, stderr_tail = false, 0, 0, ""
    ngx.log(ngx.INFO, "rtsp_pull: started pid=", proc_pid,
            " gen=", generation, " stream=", STREAM)
    supervise(p, generation)
    return true
end

-- Backoff for a start that did not produce a process: without it, a missing
-- ffmpeg or a broken secret would retry twice a second forever.
local function start_failed()
    next_try = ngx.time() + backoff
    backoff = math.min(backoff * 2, MAX_BACKOFF)
end

local function tick(premature)
    if premature then
        return
    end

    -- Both inputs are read every tick, because either one alone is wrong: the
    -- demand key expires while a viewer is still handshaking, and `clients` is
    -- zero during that same window.
    local wanted = ngx.shared.rtsp_pull:get(DEMAND_KEY) ~= nil
    local watching = (viewer_count() or 0) > 0

    if proc then
        if stopping then
            -- SIGTERM is a request, not a guarantee: ffmpeg stuck in a device
            -- read may ignore it, and a pull that never exits would hold the
            -- viewer's stream down after the next demand.
            if term_at > 0 and ngx.now() - term_at > TERM_GRACE then
                ngx.log(ngx.ERR, "rtsp_pull: pid=", proc_pid,
                        " survived SIGTERM; sending SIGKILL")
                proc:kill(SIGKILL)
                term_at = 0   -- escalate once; the supervisor clears the state
            end
            return
        end

        if watching or wanted then
            idle_since = 0
        elseif idle_since == 0 then
            idle_since = ngx.time()
        elseif ngx.time() - idle_since >= IDLE_SECONDS then
            ngx.log(ngx.INFO, "rtsp_pull: no viewer for ", IDLE_SECONDS,
                    "s, stopping pid=", proc_pid)
            stopping, term_at = true, ngx.now()
            proc:kill(SIGTERM)
        end
        return
    end

    -- No process: start one if anybody wants the stream.
    if not (watching or wanted) then
        idle_since = 0
        return
    end
    if ngx.time() < next_try then
        return
    end
    if not start_pull() then
        start_failed()
    end
end

-- init_worker_by_lua_block hook (worker 0 only; see the header).
function _M.start()
    if 0 ~= ngx.worker.id() then
        return
    end
    if not have_pipe then
        ngx.log(ngx.ERR, "rtsp_pull: ngx.pipe unavailable; on-demand pull disabled")
        return
    end
    if not os.getenv("RS500_RTSP_URL") then
        ngx.log(ngx.INFO, "rtsp_pull: RS500_RTSP_URL not set; on-demand pull disabled")
    end
    ngx.timer.every(TICK_SECONDS, tick)
end

-- exit_worker_by_lua_block hook: a pull must not outlive the worker that owns
-- it. GC would SIGKILL the child anyway; SIGTERM first lets ffmpeg close the
-- RTSP session instead of leaving the device to time it out.
function _M.stop()
    if 0 ~= ngx.worker.id() or not proc then
        return
    end
    ngx.log(ngx.INFO, "rtsp_pull: worker exiting, stopping pid=", proc_pid)
    proc:kill(SIGTERM)
end

return _M
