-- conf/rtc_history.lua - Ring-buffer time-series sampling of live stats.
--
-- The C module mirrors a stats snapshot into the `rtc_stats` shared dict every
-- second (key "stats"). This module samples that snapshot into a fixed ring of
-- per-slot records in a separate `rtc_stats_history` dict, so an operator can
-- watch totals (and derived bitrates) over the last ~25 minutes without keeping
-- the full history in nginx memory.
--
-- Storage: slot-indexed keys (O(1) write, oldest point naturally overwritten).
--   STEP = 5s buckets, CAP = 300 slots  =>  25 minute sliding window.
-- Cumulative octets are stored and diffed against the previous slot to derive
-- per-point bitrates; bps = 0 while the window is still warming up.
--
-- Only worker 0 samples, so concurrent workers never race on the same slot.
-- Exposure: GET /rtc/v1/stats/history (loopback / trusted LAN only).

local cjson = require "cjson"

local STEP = 5
local CAP = 300

local function slot_key(i)
    return "h:" .. i
end

local function now_slot()
    return math.floor(ngx.now() / STEP) % CAP
end

local function sample(premature)
    if premature then
        return
    end

    local raw = ngx.shared.rtc_stats:get("stats")
    if not raw then
        return
    end
    local ok, d = pcall(cjson.decode, raw)
    if not (ok and "table" == type(d)) then
        return
    end

    local dict = ngx.shared.rtc_stats_history
    local slot = now_slot()
    local ts = math.floor(ngx.now())
    local pt = {
        ts = ts,
        streams = d.total_streams or 0,
        clients = d.total_clients or 0,
        video_octets = d.total_video_octets or 0,
        audio_octets = d.total_audio_octets or 0,
        video_bps = 0,
        audio_bps = 0,
    }

    -- Diff cumulative octets against the previous slot to get a bitrate.
    local prev = dict:get(slot_key((slot - 1 + CAP) % CAP))
    if prev then
        local okp, pp = pcall(cjson.decode, prev)
        if okp and "table" == type(pp) and pp.ts and ts > pp.ts then
            local dt = ts - pp.ts
            local dv = pt.video_octets - (pp.video_octets or 0)
            local da = pt.audio_octets - (pp.audio_octets or 0)
            if dv > 0 then pt.video_bps = dv * 8 / dt end
            if da > 0 then pt.audio_bps = da * 8 / dt end
        end
    end

    dict:set(slot_key(slot), cjson.encode(pt))
end

local _M = { _VERSION = "0.1" }

function _M.start()
    -- One sampler (worker 0) keeps multi-worker deployments race-free.
    if 0 == ngx.worker.id() then
        ngx.timer.every(STEP, sample)
    end
end

function _M.output()
    local dict = ngx.shared.rtc_stats_history
    local points = {}
    for i = 0, CAP - 1 do
        local v = dict:get(slot_key(i))
        if v then
            local ok, pt = pcall(cjson.decode, v)
            if ok and "table" == type(pt) and pt.ts then
                points[#points + 1] = pt
            end
        end
    end
    table.sort(points, function(a, b) return a.ts < b.ts end)

    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        code = 0,
        step = STEP,
        capacity = CAP,
        points = points,
    }))
end

-- content_by_lua_file runs this file per request in the content phase;
-- require() (from init_worker) only needs the module table.
if "content" == ngx.get_phase() then
    _M.output()
end

return _M
