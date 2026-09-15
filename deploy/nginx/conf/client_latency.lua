-- conf/client_latency.lua - viewer-side end-to-end latency, storage layer.
--
-- Half of the latency a viewer sees happens after the last packet leaves this
-- server: the jitter buffer, the decode and the present. The only clock that
-- sees both halves is the one inside the browser that rendered the frame, so
-- the player page computes ingest-to-display from the server's RTCP anchor and
-- its own requestVideoFrameCallback timestamp, and posts the result to
-- conf/rtc_report.lua. The server stores it per ICE ufrag -- the same key its
-- own per-session stats use, since the ufrag is server-generated and appears in
-- the answer SDP, which is how the page reads its own identity back out.
--
-- This file is a pure module: it is require()d by stats.lua and metrics.lua and
-- must never handle a request itself. That separation is not stylistic. The
-- obvious alternative -- serve on `ngx.get_phase() == "content"` at the bottom,
-- the way rtc_history.lua does -- breaks the moment a *content-phase* handler
-- requires this module: requiring it from stats.lua would re-enter the report
-- handler with stats.lua's request still in flight, send a response for it, and
-- then stats.lua's own header writes fail with "attempt to set ngx.status after
-- sending out response headers". A module that is safe to require has to have
-- no entry point at all.
--
-- Everything a viewer sends ends up as a shared-dict key, a JSON field and a
-- Prometheus label, so every field is validated here; see
-- scripts/e2e-client-latency.sh for the contract.

local cjson = require "cjson"

local DICT_NAME = "rtc_client_latency"
local TTL = 20           -- seconds; four missed reports at one per 5s
local UFRAG_MAX = 63     -- RFC 5245 ice-char run; also the key suffix
local STREAM_MAX = 127
local E2E_MAX_MS = 60000 -- a minute of latency is not a sample, it is a bug
-- Ingest-to-display is allowed to come out slightly negative, and does. The
-- page's anchor pairs the newest packet's RTP timestamp with the moment the
-- server built the report, so the timestamp-to-wall-clock mapping carries up to
-- one frame interval of negative bias -- on a fast path (loopback, a LAN) the
-- true value is near zero and the bias is what dominates the reading. The floor
-- matches the window the page itself accepts, so nothing it can produce is
-- refused; the page drops anything below -1000 before it is ever sent.
local E2E_MIN_MS = -1000
local GET_KEYS_MAX = 1000

-- ICE ufrag / stream charset. Deliberately an allowlist: these values become a
-- shared-dict key and (via metrics.lua) a Prometheus label value, and the one
-- thing that must never pass is a character that could forge or split either.
-- ice-char is ALPHA / DIGIT / "+" / "/"; the rest are what stream names use.
local SAFE = "^[%w%+%/_%=%-%.]+$"

local _M = {
    _VERSION = "0.1",
    DICT_NAME = DICT_NAME,
    TTL = TTL,
    GET_KEYS_MAX = GET_KEYS_MAX,
}

local function dict()
    return ngx.shared[DICT_NAME]
end

-- The dict is declared in nginx.conf, but these .lua files are hot-copied into
-- a running instance (run.sh sync) while the declaration only takes effect on a
-- restart. Guarding here is what keeps that staged deploy from taking /metrics
-- and /rtc/v1/stats down with it: both require this module, and both must
-- degrade to "no client latency" rather than a 500.
function _M.ready()
    return nil ~= dict()
end

local function num_field(t, k, lo, hi, required)
    local v = t[k]
    if nil == v then
        if required then
            return nil, k .. " is required"
        end
        return nil
    end
    if "number" ~= type(v) then
        return nil, k .. " must be a number"
    end
    -- JSON has no NaN or Infinity literal, but 1e400 decodes to inf, and inf
    -- passes every comparison below. Reject it explicitly.
    if v ~= v or v == math.huge or v == -math.huge then
        return nil, k .. " must be finite"
    end
    if v < lo or v > hi then
        return nil, k .. " out of range"
    end
    return v
end

local function str_field(t, k, max)
    local v = t[k]
    if "string" ~= type(v) then
        return nil, k .. " must be a string"
    end
    if 0 == #v or #v > max then
        return nil, k .. " must be 1.." .. max .. " bytes"
    end
    if not v:match(SAFE) then
        return nil, k .. " has characters outside the allowed set"
    end
    return v
end

-- Validate one report. Returns the normalized table, or nil + reason.
function _M.validate(raw)
    if "table" ~= type(raw) then
        return nil, "body must be a JSON object"
    end

    local stream, err = str_field(raw, "stream", STREAM_MAX)
    if not stream then
        return nil, err
    end
    local ufrag
    ufrag, err = str_field(raw, "ufrag", UFRAG_MAX)
    if not ufrag then
        return nil, err
    end
    local e2e
    e2e, err = num_field(raw, "e2e_ms", E2E_MIN_MS, E2E_MAX_MS, true)
    if not e2e then
        return nil, err
    end

    local out = { stream = stream, ufrag = ufrag, e2e_ms = e2e }
    local optional = {
        { "e2e_min", E2E_MIN_MS, E2E_MAX_MS },
        { "frames", 0, 1e9 },
        { "jb_ms", 0, E2E_MAX_MS },
        { "decode_ms", 0, E2E_MAX_MS },
        { "rtt_ms", 0, E2E_MAX_MS },
    }
    for _, spec in ipairs(optional) do
        local v
        v, err = num_field(raw, spec[1], spec[2], spec[3], false)
        if err then
            return nil, err
        end
        if v then
            out[spec[1]] = v
        end
    end
    return out
end

-- Store a validated report. Returns true, or nil + reason.
function _M.store(rep)
    rep.ts = ngx.time()
    local encoded = cjson.encode(rep)
    if "string" ~= type(encoded) then
        return nil, "could not encode"
    end
    local ok, err = dict():set("c:" .. rep.ufrag, encoded, TTL)
    if not ok then
        return nil, err
    end
    return true
end

-- The reader side, for consumers that already hold a ufrag: metrics.lua and
-- stats.lua join their own per-session list against this.
function _M.get(ufrag)
    if not _M.ready() then
        return nil
    end
    if "string" ~= type(ufrag) or "" == ufrag then
        return nil
    end
    local raw = dict():get("c:" .. ufrag)
    if not raw then
        return nil
    end
    local ok, v = pcall(cjson.decode, raw)
    if not ok or "table" ~= type(v) then
        return nil
    end
    return v
end

-- Every live entry, newest last. get_keys is O(n) over the dict and takes its
-- lock, which is why this is only reached from the read-only admin path
-- (rtc_report.lua's GET) and why it is capped: one key per live viewer with a
-- 20s TTL, so the cap sits far above any real deployment and the cost stays
-- bounded even if it is somehow exceeded.
function _M.dump()
    if not _M.ready() then
        return {}
    end
    local d = dict()
    local out = {}
    for _, k in ipairs(d:get_keys(GET_KEYS_MAX)) do
        if "c:" == k:sub(1, 2) then
            local raw = d:get(k)
            local ok, v = pcall(cjson.decode, raw)
            if ok and "table" == type(v) then
                v.age_s = ngx.time() - (v.ts or 0)
                v.ttl_s = d:ttl(k)
                out[#out + 1] = v
            end
        end
    end
    table.sort(out, function(a, b) return (a.ufrag or "") < (b.ufrag or "") end)
    return out
end

return _M
