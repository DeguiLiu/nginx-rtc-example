-- WebRTC play authorization for /rtc/v1/play/ signaling.
-- Key lookup goes through the dynamic config module (lua_shared_dict), so keys
-- can be hot-updated without nginx reload. Maps to the patent's "manage HTTP
-- requests that create WebRTC sessions".
local cjson = require "cjson"
local config = require "config"

ngx.log(ngx.ERR, "rtc_auth: ENTER remote=", ngx.var.remote_addr, " ct=", ngx.var.content_type, " len=", ngx.var.content_length)

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

local delay, err = lim:incoming(ngx.var.binary_remote_addr, true)
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

ngx.req.read_body()
local body = ngx.req.get_body_data()
if not body then
    ngx.log(ngx.ERR, "rtc_auth: no request body")
    return ngx.exit(400)
end

local ok, req = pcall(cjson.decode, body)
if not ok or "table" ~= type(req) or "string" ~= type(req.streamurl) then
    ngx.log(ngx.ERR, "rtc_auth: bad json, body_len=", #body, " decode_ok=", tostring(ok))
    return ngx.exit(400)
end

-- Parse app/stream from webrtc://host/app/stream.
local app, stream = req.streamurl:match("^webrtc://[^/]+/([^/]+)/([^/]+)$")
if not app or not stream then
    ngx.log(ngx.ERR, "rtc_auth: bad streamurl=", tostring(req.streamurl))
    return ngx.exit(400)
end

if not config.verify(app .. "/" .. stream, req.t, req.sign) then
    ngx.log(ngx.ERR, "rtc_auth: TOKEN DENIED app=", app, " stream=", stream,
            " t=", tostring(req.t), " sign=", tostring(req.sign))
    return ngx.exit(403)
end

ngx.log(ngx.ERR, "rtc_auth: PASS app=", app, " stream=", stream)
