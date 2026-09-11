-- WHIP ingest authorization for /whip/endpoint.
--
-- That location had no access phase at all: any client that could reach the
-- port could publish any stream name, while RTMP ingest has required a token
-- since it was written. The C handler (rtc_whip) parses only the SDP body and
-- knows nothing about credentials, so the token rides in the query string next
-- to app/stream -- the shape the FLV and RTMP paths already use, verified
-- against the same publish secret. Publishing is publishing, whichever
-- transport carries it.
--
-- Query args rather than a header: client/whip_push.mjs signs its own token
-- from WHIP_KEY and appends "t=..&sign=.." to its URL, so the credential sits
-- beside app/stream, exactly where the FLV and RTMP paths already put it.
local ngx = ngx
local config = require "config"

local app = ngx.var.arg_app
local stream = ngx.var.arg_stream
local t = ngx.var.arg_t
local sign = ngx.var.arg_sign

if not app or not stream then
    return ngx.exit(400)
end

if not config.verify(app .. "/" .. stream, t, sign, "publish") then
    -- JSON, not nginx's HTML error page: the WHIP client parses the body, and
    -- an HTML 403 reads as a transport failure rather than a token failure.
    ngx.log(ngx.ERR, "whip_auth: TOKEN DENIED app=", app, " stream=", stream)
    ngx.status = 403
    ngx.header.content_type = "application/json"
    ngx.say('{"code":403,"message":"publish token required"}')
    return ngx.exit(403)
end
