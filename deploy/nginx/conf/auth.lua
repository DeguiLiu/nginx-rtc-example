-- WebRTC play authorization for /rtc/v1/play/ signaling.
-- Key lookup goes through the dynamic config module (lua_shared_dict), so keys
-- can be hot-updated without nginx reload. Maps to the patent's "manage HTTP
-- requests that create WebRTC sessions".
local ngx = ngx
local cjson = require "cjson"
local config = require "config"

-- Log levels: server-side failures (limiter init / runtime) and authorization
-- denials stay at ERR -- nginx's own auth_basic logs "user not found" /
-- "password mismatch" at ERR too. Malformed client input is a bad request, not
-- a server error, so it goes to INFO (nginx core logs "client sent invalid ..."
-- at INFO); otherwise any scanner spraying this endpoint fills error.log.
-- Successful plays are not logged at all: the access log already has them.

-- Rate limit: 30 play requests/min per client IP (leaky bucket via the
-- official lua-resty-limit-traffic). Requests within the burst allowance are
-- served immediately; beyond burst -> 429 JSON (a plain ngx.exit(429) sends
-- nginx's HTML error page, which breaks JSON.parse on the player side).
local limit_req = require "resty.limit.req"
local lim, err = limit_req.new("rate_limit", 0.5, 5)
if not lim then
    ngx.log(ngx.ERR, "rtc_auth: limit_req init failed: ", err)
    return ngx.exit(500)
end

-- Loopback is exempt. The bucket is keyed by address, so a guard running on
-- this host draws on 127.0.0.1's allowance -- the same one the player page and
-- `run.sh verify` use. scripts/e2e-auth.sh asserts on this endpoint's status
-- codes, so it would both spend a real viewer's burst and start reading its own
-- 429s as the authorization failures it is testing for. Everything else that
-- loopback reaches here (/rtc/v1/stats, /metrics, /admin/*) is already trusted,
-- and remote_addr cannot be forged: it is the peer address of the completed
-- handshake, not anything the request carries.
--
-- The match is on remote_addr, the dotted-quad text: binary_remote_addr (used
-- below as the bucket key, where its 4 packed bytes are the point) would never
-- equal "127.0.0.1".
local TRUSTED = { ["127.0.0.1"] = true, ["::1"] = true }

if not TRUSTED[ngx.var.remote_addr] then
    local delay, err = lim:incoming("play:" .. ngx.var.binary_remote_addr, true)
    if not delay then
        if err == "rejected" then
            ngx.status = 429
            ngx.header.content_type = "application/json"
            ngx.say('{"code":429,"message":"rate limited: too many play requests, retry in a few seconds"}')
            return ngx.exit(429)
        end
        ngx.log(ngx.ERR, "rtc_auth: limit_req failed: ", err)
        return ngx.exit(500)
    end
    -- delay > 0 means we are draining the burst; signaling latency budget is
    -- small, so treat it as pass-through rather than ngx.sleep(delay).
end

ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body then
    -- get_body_data() returns nil for two very different requests: one with no
    -- body at all, and one nginx spilled to a temp file because it exceeded
    -- client_body_buffer_size. The module caps signaling bodies (rtc_max_sdp_len,
    -- itself clamped to that buffer), so the second case is always an oversized
    -- offer -- and answering it "no request body" sends the caller hunting for a
    -- missing field instead of looking at the size.
    if ngx.req.get_body_file() then
        ngx.log(ngx.WARN, "rtc_auth: request body spilled to disk; raise "
                          .. "client_body_buffer_size and rtc_max_sdp_len")
        ngx.status = 413
        ngx.header.content_type = "application/json"
        ngx.say('{"code":413,"message":"request body too large"}')
        return ngx.exit(413)
    end
    ngx.log(ngx.INFO, "rtc_auth: no request body")
    return ngx.exit(400)
end

local ok, req = pcall(cjson.decode, body)
if not ok or "table" ~= type(req) or "string" ~= type(req.streamurl) then
    ngx.log(ngx.INFO, "rtc_auth: bad json, body_len=", #body, " decode_ok=", tostring(ok))
    return ngx.exit(400)
end

-- Parse app/stream from webrtc://host/app/stream.
local app, stream = req.streamurl:match("^webrtc://[^/]+/([^/]+)/([^/]+)$")
if not app or not stream then
    ngx.log(ngx.INFO, "rtc_auth: bad streamurl=", tostring(req.streamurl))
    return ngx.exit(400)
end

if not config.verify(app .. "/" .. stream, req.t, req.sign, "play") then
    ngx.log(ngx.ERR, "rtc_auth: TOKEN DENIED app=", app, " stream=", stream,
            " t=", tostring(req.t), " sign=", tostring(req.sign))
    return ngx.exit(403)
end
